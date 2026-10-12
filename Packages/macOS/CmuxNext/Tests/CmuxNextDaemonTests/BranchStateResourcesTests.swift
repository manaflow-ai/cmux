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
            await Self.until(store) { store.servesStateResources }
            let (key, pane, _) = try await h.workspaceWithTerminal("retention")
            for _ in 0..<3 {
                let created = try await h.connection.newTab(in: pane, options: SpawnOptions(cwd: h.root.path, workspace: key))
                try await h.connection.closeTab(created.surface)
                try await Task.sleep(for: .milliseconds(5))
            }
            await Self.until(store) { store.closedItems.count == 3 }
            let items = await store.closedItems.sorted { $0.closedAtMs > $1.closedAtMs }
            let now = items[0].closedAtMs
            #expect(ClosedRetention(maxGroups: 0, maxAgeDays: 0).prune(items, nowMs: now) == nil)
            #expect(ClosedRetention(maxGroups: 3, maxAgeDays: 1).prune(items, nowMs: now) == nil)

            let byCount = try #require(ClosedRetention(maxGroups: 2, maxAgeDays: 0).prune(items, nowMs: now))
            try await h.connection.state.pruneClosed(byCount)
            await Self.until(store) { store.closedItems.count == 2 }
            #expect(await Set(store.closedItems.map(\.id)) == Set(items.prefix(2).map(\.id)))

            // A day after the newest close, everything older than it is over a one-day limit.
            let kept = Array(items.prefix(2))
            let byAge = try #require(ClosedRetention(maxGroups: 0, maxAgeDays: 1).prune(kept, nowMs: now + 86_400_000))
            try await h.connection.state.pruneClosed(byAge)
            await Self.until(store) { store.closedItems.count == 1 }
            #expect(await store.closedItems.map(\.id) == [items[0].id])
        }
    }

    @Test func ephemeralStatusScreenAndTabStateReachTheRecords() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            let created = try await h.connection.state.createWorkspace(name: "eph", ephemeral: true, terminal: true)
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

    @Test func groupsMadeThroughV2ShowInTheTree() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            try await store.waitUntil("state resources served", timeout: .seconds(20)) { store.servesStateResources }
            let created = try await h.connection.state.createWorkspace(name: "groups", ephemeral: false, terminal: true)
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
}
