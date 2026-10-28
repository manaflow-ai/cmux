import Foundation
import Testing
@testable import CmuxNextDaemon

/// The state resources against the pinned branch cmux-tui: the store
/// mirrors them from `session.events`, and the v2 mutations land in it.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchStateResourcesTests {
    @Test func closedTabsAreRecordedAndReopened() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            let (key, pane, _) = try await h.workspaceWithTerminal("closed")
            let created = try await h.connection.newTab(in: pane, options: SpawnOptions(cwd: h.root.path, workspace: key))
            try await h.connection.closeTab(created.surface)
            try await store.waitUntil("the closed tab recorded", timeout: .seconds(20)) { store.closedItems.contains { $0.kind == .tab } }
            let item = try #require(await store.closedItems.first { $0.kind == .tab })
            #expect(item.paneID != nil)
            let reopened = try await h.connection.state.reopenClosed(item.id)
            #expect(reopened.tabIDs.count == 1)
            try await store.waitUntil("the reopened tab out of closed history", timeout: .seconds(20)) { !store.closedItems.contains { $0.id == item.id } }
        }
    }

    /// `history.closed.maxGroups` and `maxAgeDays` (reopen-closed.md S1b):
    /// the prune a mirror over a limit asks for deletes the oldest groups
    /// in the daemon, and the store follows.
    @Test func closedRetentionDeletesTheOldestGroups() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            let (key, pane, _) = try await h.workspaceWithTerminal("retention")
            for _ in 0..<3 {
                let created = try await h.connection.newTab(in: pane, options: SpawnOptions(cwd: h.root.path, workspace: key))
                try await h.connection.closeTab(created.surface)
                try await Task.sleep(for: .milliseconds(5))
            }
            try await store.waitUntil("three closed tabs recorded", timeout: .seconds(20)) { store.closedItems.count == 3 }
            let items = await store.closedItems.sorted { $0.closedAtMs > $1.closedAtMs }
            let now = items[0].closedAtMs
            #expect(ClosedRetention(maxGroups: 0, maxAgeDays: 0).prune(items, nowMs: now) == nil)
            #expect(ClosedRetention(maxGroups: 3, maxAgeDays: 1).prune(items, nowMs: now) == nil)

            let byCount = try #require(ClosedRetention(maxGroups: 2, maxAgeDays: 0).prune(items, nowMs: now))
            try await h.connection.state.pruneClosed(byCount)
            try await store.waitUntil("the oldest group deleted", timeout: .seconds(20)) { store.closedItems.count == 2 }
            #expect(await Set(store.closedItems.map(\.id)) == Set(items.prefix(2).map(\.id)))

            // A day after the newest close, everything older than it is over a one-day limit.
            let kept = Array(items.prefix(2))
            let byAge = try #require(ClosedRetention(maxGroups: 0, maxAgeDays: 1).prune(kept, nowMs: now + 86_400_000))
            try await h.connection.state.pruneClosed(byAge)
            try await store.waitUntil("the older group deleted", timeout: .seconds(20)) { store.closedItems.count == 1 }
            #expect(await store.closedItems.map(\.id) == [items[0].id])
        }
    }

    /// workspace-description-v1 and workspace-status-v1: `workspace.update` sets both, the store
    /// mirrors them from the workspace's `extra`, and `.clear` takes each back alone.
    @Test func descriptionAndTaskStatusReachTheWorkspace() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            #expect(await store.supports(DaemonCapability.workspaceDescription.rawValue))
            #expect(await store.supports(DaemonCapability.workspaceStatus.rawValue))
            let created = try await h.connection.state.createWorkspace(name: "notes", ephemeral: false, terminal: false, focus: true)
            let id = created.workspaceID
            try await h.connection.state.updateWorkspace(id, description: .set("Ship it\n- notes"), taskStatus: .set(.needsAttention))
            try await store.waitUntil("the notes", timeout: .seconds(20)) { store.workspace(resourceID: id)?.taskStatus == .needsAttention }
            #expect(await store.workspace(resourceID: id)?.workspaceDescription == "Ship it\n- notes")
            try await h.connection.state.updateWorkspace(id, description: .clear)
            try await store.waitUntil("the description cleared", timeout: .seconds(20)) { store.workspace(resourceID: id)?.workspaceDescription == nil }
            #expect(await store.workspace(resourceID: id)?.taskStatus == .needsAttention, "clearing the description keeps the lane")
            try await h.connection.state.updateWorkspace(id, taskStatus: .clear)
            try await store.waitUntil("automatic again", timeout: .seconds(20)) { store.workspace(resourceID: id)?.taskStatus == nil }
        }
    }

    @Test func ephemeralStatusScreenAndTabStateReachTheRecords() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            let created = try await h.connection.state.createWorkspace(name: "eph", ephemeral: true, terminal: true, focus: true)
            try await store.waitUntil("the ephemeral workspace", timeout: .seconds(20)) { store.workspace(resourceID: created.workspaceID)?.ephemeral == true }

            try await h.connection.state.stateMutation("workspace_status.set", [
                "workspace": .string(created.workspaceID.rawValue), "key": .string("build"), "text": .string("Building"),
            ])
            try await h.connection.state.stateMutation("workspace_progress.set", [
                "workspace": .string(created.workspaceID.rawValue), "value": .number(0.5),
            ])
            try await store.waitUntil("its status and progress", timeout: .seconds(20)) {
                let status = store.workspace(resourceID: created.workspaceID)?.status
                return status?.line == "Building" && status?.progress?.value == 0.5
            }

            let screen = try #require(await store.workspace(resourceID: created.workspaceID)?.screens.first?.resourceID)
            try await h.connection.state.updateScreen(screen, pinned: true, color: .set("green"))
            try await store.waitUntil("the pinned green screen", timeout: .seconds(20)) {
                let model = store.workspace(resourceID: created.workspaceID)?.screens.first
                return model?.pinned == true && model?.color == "green"
            }

            let tab = try #require(created.tabID)
            try await h.connection.state.updateTabRecord(tab, zoom: .set(1.25))
            try await store.waitUntil("the tab zoom", timeout: .seconds(20)) {
                store.workspace(resourceID: created.workspaceID)?.screens.flatMap(\.panes).flatMap(\.tabs)
                    .first { $0.resourceID == tab }?.zoom == 1.25
            }
            try await h.connection.state.setTabPinned(tab, true)
            try await store.waitUntil("the pinned tab", timeout: .seconds(20)) {
                store.workspace(resourceID: created.workspaceID)?.screens.flatMap(\.panes).flatMap(\.tabs)
                    .first { $0.resourceID == tab }?.pinned == true
            }
        }
    }

    /// tab-mark-unread-v1: Mark Tab Unread marks a tab with no notification;
    /// the store mirrors the mark from `extra.marked_unread` (the tab shows
    /// unread, its notification state untouched), and a clear removes it.
    @Test func aTabMarkedUnreadShowsUnreadUntilCleared() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            #expect(h.identity.supports(DaemonCapability.tabMarkUnread.rawValue))
            let created = try await h.connection.state.createWorkspace(name: "mark-unread", ephemeral: false, terminal: true, focus: true)
            let tab = try #require(created.tabID)
            @MainActor func model() -> TabModel? {
                store.workspace(resourceID: created.workspaceID)?.screens.flatMap(\.panes).flatMap(\.tabs).first { $0.resourceID == tab }
            }
            try await store.waitUntil("the tab", timeout: .seconds(20)) { model() != nil }
            #expect(await model()?.showsUnread == false)
            try await h.connection.state.updateTabRecord(tab, markedUnread: true)
            try await store.waitUntil("the tab marked unread", timeout: .seconds(20)) { model()?.markedUnread == true }
            #expect(await model()?.showsUnread == true)
            #expect(await model()?.hasUnread == false, "the mark is not a notification")
            try await h.connection.state.updateTabRecord(tab, zoom: .set(1.25))
            try await store.waitUntil("the tab zoom", timeout: .seconds(20)) { model()?.zoom == 1.25 }
            #expect(await model()?.markedUnread == true, "another field keeps the mark")
            try await h.connection.state.updateTabRecord(tab, markedUnread: false)
            try await store.waitUntil("the mark cleared", timeout: .seconds(20)) { model()?.markedUnread == false }
            #expect(await model()?.zoom == 1.25)
        }
    }

    @Test func groupsMadeThroughV2ShowInTheTree() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            let created = try await h.connection.state.createWorkspace(name: "groups", ephemeral: false, terminal: true, focus: true)
            let tab = try #require(created.tabID)
            let group = try await h.connection.state.createTabGroup(tabs: [tab], name: "g", color: "blue")
            try await store.waitUntil("the tab group", timeout: .seconds(20)) {
                store.workspace(resourceID: created.workspaceID)?.screens.flatMap(\.panes).flatMap(\.tabGroups)
                    .contains { $0.id.rawValue == group.id } == true
            }
            let screen = try #require(await store.workspace(resourceID: created.workspaceID)?.screens.first?.resourceID)
            let screenGroup = try await h.connection.state.createScreenGroup(screens: [screen], name: "s", color: "red")
            try await store.waitUntil("the screen group", timeout: .seconds(20)) {
                store.workspace(resourceID: created.workspaceID)?.screenGroups.contains { $0.id.rawValue == screenGroup.id } == true
            }
        }
    }

    /// Stash (`stash-v1`) through the Swift client: OneTab groups import as
    /// stashes (pages that are not http(s) are skipped), list newest first,
    /// and delete by member or whole.
    @Test func oneTabImportsListAndDeletesAsStashes() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            #expect(await h.connection.identity?.supports(DaemonCapability.stash.rawValue) == true, "the same-tree daemon serves stash-v1")
            let state = h.connection.state
            let older = StateResourceClient.StashImportGroup(name: "reading", pages: [
                .init(url: "https://example.com/a", title: "A"),
                .init(url: "file:///etc/hosts", title: nil),
            ])
            let newer = StateResourceClient.StashImportGroup(name: "later", pages: [
                .init(url: "https://example.com/b", title: "B"),
                .init(url: "https://example.com/c", title: nil),
            ])
            let imported = try await state.importOneTab([older, newer], engine: nil)
            #expect(imported.importedTabs == 3)
            #expect(imported.skippedTabs == 1, "a page that is not http(s) is never stashed")

            let stashes = try await state.stashes()
            #expect(stashes.count == 2)
            let later = try #require(stashes.first { $0.name == "later" })
            let reading = try #require(stashes.first { $0.name == "reading" })
            #expect(later.members.map(\.url) == ["https://example.com/b", "https://example.com/c"], "members keep restore order")
            #expect(reading.members.map(\.url) == ["https://example.com/a"])
            #expect(later.members.allSatisfy { $0.workspaceID == nil }, "an imported page left no workspace")

            try await state.deleteStash(later.id, members: [later.members[0].id])
            #expect(try await state.stashes().first { $0.id == later.id }?.members.map(\.url) == ["https://example.com/c"])
            try await state.deleteStash(reading.id)
            #expect(try await state.stashes().map(\.id) == [later.id])
        }
    }
}
