import Foundation
import Observation
import Testing
@testable import CmuxNextDaemon

/// The state resources against the pinned branch cmux-tui: the store
/// mirrors them from `session.events`, and the v2 mutations land in it.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchStateResourcesTests {
    /// Waits for `condition` on the store, observing it (no polling).
    @MainActor static func until(_ store: DaemonStore, _ condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        for await done in Observations({ condition() }) where done { return }
    }

    @Test func closedTabsAreRecordedAndReopened() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            await Self.until(store) { store.servesStateResources }
            let (key, pane, _) = try await h.workspaceWithTerminal("closed")
            let created = try await h.connection.newTab(in: pane, options: SpawnOptions(cwd: h.root.path, workspace: key))
            try await h.connection.closeTab(created.surface)
            await Self.until(store) { store.closedItems.contains { $0.kind == .tab } }
            let item = try #require(await store.closedItems.first { $0.kind == .tab })
            #expect(item.paneID != nil)
            let reopened = try await h.connection.state.reopenClosed(item.id)
            #expect(reopened.tabIDs.count == 1)
            await Self.until(store) { !store.closedItems.contains { $0.id == item.id } }
        }
    }

    @Test func ephemeralStatusScreenAndTabStateReachTheRecords() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            await Self.until(store) { store.servesStateResources }
            let created = try await h.connection.state.createWorkspace(name: "eph", ephemeral: true, terminal: true)
            await Self.until(store) { store.workspace(resourceID: created.workspaceID)?.ephemeral == true }

            try await h.connection.state.stateMutation("workspace_status.set", [
                "workspace": .string(created.workspaceID.rawValue), "key": .string("build"), "text": .string("Building"),
            ])
            try await h.connection.state.stateMutation("workspace_progress.set", [
                "workspace": .string(created.workspaceID.rawValue), "value": .number(0.5),
            ])
            await Self.until(store) {
                let status = store.workspace(resourceID: created.workspaceID)?.status
                return status?.line == "Building" && status?.progress?.value == 0.5
            }

            let screen = try #require(await store.workspace(resourceID: created.workspaceID)?.screens.first?.resourceID)
            try await h.connection.state.updateScreen(screen, pinned: true, color: .set("green"))
            await Self.until(store) {
                let model = store.workspace(resourceID: created.workspaceID)?.screens.first
                return model?.pinned == true && model?.color == "green"
            }

            let tab = try #require(created.tabID)
            try await h.connection.state.updateTabRecord(tab, zoom: .set(1.25))
            await Self.until(store) {
                store.workspace(resourceID: created.workspaceID)?.screens.flatMap(\.panes).flatMap(\.tabs)
                    .first { $0.resourceID == tab }?.zoom == 1.25
            }
            try await h.connection.state.setTabPinned(tab, true)
            await Self.until(store) {
                store.workspace(resourceID: created.workspaceID)?.screens.flatMap(\.panes).flatMap(\.tabs)
                    .first { $0.resourceID == tab }?.pinned == true
            }
        }
    }

    @Test func groupsMadeThroughV2ShowInTheTree() async throws {
        try await BranchDaemonHarness.with(sessionEvents: true) { h in
            let store = h.store
            await Self.until(store) { store.servesStateResources }
            let created = try await h.connection.state.createWorkspace(name: "groups", ephemeral: false, terminal: true)
            let tab = try #require(created.tabID)
            let group = try await h.connection.state.createTabGroup(tabs: [tab], name: "g", color: "blue")
            await Self.until(store) {
                store.workspace(resourceID: created.workspaceID)?.screens.flatMap(\.panes).flatMap(\.tabGroups)
                    .contains { $0.id.rawValue == group.id } == true
            }
            let screen = try #require(await store.workspace(resourceID: created.workspaceID)?.screens.first?.resourceID)
            let screenGroup = try await h.connection.state.createScreenGroup(screens: [screen], name: "s", color: "red")
            await Self.until(store) {
                store.workspace(resourceID: created.workspaceID)?.screenGroups.contains { $0.id.rawValue == screenGroup.id } == true
            }
        }
    }
}
