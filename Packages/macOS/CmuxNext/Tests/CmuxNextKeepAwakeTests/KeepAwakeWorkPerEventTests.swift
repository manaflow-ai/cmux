@testable import CmuxNextDaemon
@testable import CmuxNextKeepAwake
import Foundation
import Observation
import os
import Testing

/// No O(all) work per event (perf-lead.md cause 6). Whether a local agent works
/// (`KeepAwakeService.agentsWorking`) is followed for the whole session. It walked every
/// workspace's screens, every pane and every tab and read each tab's status, inside the
/// observation: every tab added, closed or moved anywhere, and every reorder, woke it and walked
/// the whole tree again (STRESS: thousands of tracked reads per Cmd-T or Cmd-W). Only a tab that
/// carries a status fact (an agent hook, an OSC 7501 record, a running command, an agent session)
/// can report working: the check reads those tabs alone.
@MainActor
struct KeepAwakeWorkPerEventTests {
    /// `workspaces` workspaces, each with two screens of one pane with `tabs` terminal tabs.
    private static func tree(workspaces: Int, tabs: Int) -> DaemonTree {
        var next: UInt64 = 0
        func id() -> UInt64 { next += 1; return next }
        return DaemonTree(workspaces: (0..<workspaces).map { index in
            let screens = (0..<2).map { _ in
                let pane = PaneID(rawValue: id())
                let tabs = (0..<tabs).map { _ in TabSnapshot(surface: SurfaceID(rawValue: id()), title: "~") }
                return ScreenSnapshot(id: ScreenID(rawValue: id()), layout: .leaf(pane), panes: [PaneSnapshot(id: pane, tabs: tabs)])
            }
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id()), key: nil, name: "w\(index)", screens: screens)
        })
    }

    private static func liveStore(workspaces: Int, tabs: Int) throws -> DaemonStore {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"keep-awake-work-test","generation":"g1"}"#
        let store = DaemonStore()
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        store.apply(snapshot: tree(workspaces: workspaces, tabs: tabs))
        return store
    }

    /// 100 workspaces, 200 panes, 800 tabs, one agent working: a reorder in another workspace
    /// (no tab with a status fact came, went or changed) does not wake the check.
    @Test func aTabListChangeElsewhereDoesNotWakeTheAgentWorkCheck() throws {
        let store = try Self.liveStore(workspaces: 100, tabs: 4)
        let working = try #require(store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        working.setAgent(AgentStatus(surface: working.surface, state: .working))
        let far = try #require(store.workspaces.last)
        let farPane = try #require(far.screens.first?.panes.first)

        let reached = OSAllocatedUnfairLock(initialState: false)
        let isWorking = withObservationTracking {
            KeepAwakeService.agentsWorking(store)
        } onChange: {
            reached.withLock { $0 = true }
        }
        #expect(isWorking)

        far.screens = Array(far.screens.reversed())
        farPane.tabs = Array(farPane.tabs.reversed())
        #expect(!reached.withLock { $0 },
                "the agent work check tracked every workspace's screens and every pane's tabs (O(all) per tab-list change)")
    }

    /// A working agent's title tick (or a shell's preexec title) reaches the store as the tab's
    /// tab-changed, which indexes the tab again: the same record leaves and rejoins the index in
    /// one write, so the set of tabs with a status fact does not move and the check stays asleep.
    @Test func aRenameOfAWorkingTabDoesNotWakeTheAgentWorkCheck() throws {
        let store = try Self.liveStore(workspaces: 2, tabs: 2)
        let workspace = try #require(store.workspaces.first)
        let screen = try #require(workspace.screens.first)
        let pane = try #require(screen.panes.first)
        let working = try #require(pane.tabs.first)
        working.setAgent(AgentStatus(surface: working.surface, state: .working))

        let reached = OSAllocatedUnfairLock(initialState: false)
        let isWorking = withObservationTracking {
            KeepAwakeService.agentsWorking(store)
        } onChange: {
            reached.withLock { $0 = true }
        }
        #expect(isWorking)

        for title in ["⠋ claude", "⠙ claude", "⠹ claude"] {
            let delta = TabDelta(workspace: workspace.handle, screen: screen.handle, pane: pane.handle, surface: working.surface,
                                 index: nil, entity: TabSnapshot(surface: working.surface, title: title))
            #expect(store.apply(.tabChanged(delta)) == DaemonStore.Followup.none)
        }
        #expect(working.title == "⠹ claude", "the rename did not reach the tab")
        #expect(KeepAwakeService.agentsWorking(store), "a renamed working tab stopped counting")
        #expect(!reached.withLock { $0 },
                "a rename reindexed the working tab and rewrote the status-fact set (the keep-awake check woke)")
    }

    /// The narrow read keeps the answer: a tab whose agent starts working holds the Mac awake,
    /// and the hold goes when it stops or its tab leaves the tree.
    @Test func aTabWhoseAgentWorksHoldsAndLetsGo() throws {
        let store = try Self.liveStore(workspaces: 2, tabs: 2)
        let pane = try #require(store.workspaces.first?.screens.first?.panes.first)
        let tab = try #require(pane.tabs.first)
        #expect(!KeepAwakeService.agentsWorking(store))
        tab.setAgent(AgentStatus(surface: tab.surface, state: .working))
        #expect(KeepAwakeService.agentsWorking(store), "a working agent did not count")
        tab.setAgent(AgentStatus(surface: tab.surface, state: .idle))
        #expect(!KeepAwakeService.agentsWorking(store), "an idle agent counted as working")
        tab.setAgent(AgentStatus(surface: tab.surface, state: .working))
        #expect(KeepAwakeService.agentsWorking(store))
        // The tab leaves the tree (the workspace closes): it no longer counts.
        var tree = Self.tree(workspaces: 2, tabs: 2)
        tree.workspaces.removeFirst()
        store.apply(snapshot: tree)
        #expect(!KeepAwakeService.agentsWorking(store), "a tab the tree dropped still kept the Mac awake")
    }
}
