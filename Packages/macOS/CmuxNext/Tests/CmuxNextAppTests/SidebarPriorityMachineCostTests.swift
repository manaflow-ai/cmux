import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDaemon
import Foundation
import Observation
import Testing

/// Hot-path audit 3, H13 (2026-10-28): the Priority view's rows read each other machine's agent chats
/// (`SidebarPriorityMachine.lanes`) and a row's open finds its tab (`tab(showing:)`). Both walked every workspace,
/// screen, pane and tab of the machine's tree: O(sessions x tabs) per panel, and the panel observed every pane's tab
/// list of every Cloud VM, SSH machine and server, so a terminal opened on any of them re-ran it. CLAUDE.md "Go past
/// Chrome where cmux is scripted": a change costs the items it changes. They read the tree's agent chat tabs from
/// `StoreTabRoles` and observe only that set and those tabs.
@MainActor @Suite(.serialized) struct SidebarPriorityMachineCostTests {
    /// Set from an observation's change callback.
    nonisolated final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        nonisolated var fired: Bool { lock.withLock { value } }
        nonisolated func fire() { lock.withLock { value = true } }
    }

    static func chat(_ surface: UInt64, session: String, notice: UInt64? = nil) -> TabSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: "chat \(session)",
                              notification: notice.map { TabNotification(notification: NotificationID(rawValue: $0), unread: true, level: .warning) })
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:vm", session: session, harness: "claude"))
        return tab
    }

    /// A machine's tree: `workspaces` workspaces (handle w, screen w, pane w) of `terminals` terminals each; workspace 1
    /// also holds the chats "s-asks" (a question waiting) and "s-idle".
    static func store(workspaces: Int, terminals: Int) throws -> DaemonStore {
        let store = DaemonStore()
        let json = #"{"app":"cmux-tui","protocol":1,"session":"priority-cost","generation":"g1"}"#
        store.connectionState = .connected(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        store.apply(snapshot: DaemonTree(workspaces: (1...workspaces).map { w in
            var tabs = (0..<terminals).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64(w * 1_000 + $0)), title: "zsh") }
            if w == 1 { tabs += [chat(90_000_001, session: "s-asks", notice: 7), chat(90_000_002, session: "s-idle")] }
            let pane = PaneID(rawValue: UInt64(w))
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(w)), layout: .leaf(pane), panes: [PaneSnapshot(id: pane, tabs: tabs)])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(w)), key: nil, name: "w\(w)", screens: [screen])
        }))
        return store
    }

    static func terminalAdded(workspace w: UInt64, surface: UInt64) -> DaemonEvent {
        .tabAdded(TabDelta(workspace: WorkspaceHandle(rawValue: w), screen: ScreenID(rawValue: w), pane: PaneID(rawValue: w),
                           surface: SurfaceID(rawValue: surface), index: nil, entity: TabSnapshot(surface: SurfaceID(rawValue: surface), title: "zsh")))
    }

    @Test func aTerminalOpenedOnTheMachineReRunsNoPriorityPanel() throws {
        let store = try Self.store(workspaces: 100, terminals: 4)
        let machine = SidebarPriorityMachine(name: "gpu-box", store: store)
        let fired = Fired()
        let (lanes, shown) = withObservationTracking { (machine.lanes(), machine.tab(showing: "s-idle")) } onChange: { fired.fire() }
        #expect(Set(lanes.map(\.id)) == ["s-asks", "s-idle"])
        #expect(lanes.first { $0.id == "s-asks" }?.state == .input)
        #expect(shown == store.tab(surface: 90_000_002)?.id)
        // A script opens terminals on that machine: in another workspace, and beside the chats.
        store.apply(Self.terminalAdded(workspace: 60, surface: 60_999))
        store.apply(Self.terminalAdded(workspace: 1, surface: 1_999))
        #expect(!fired.fired, "a terminal opened on another machine re-ran the Priority view's rows")
    }

    @Test func aChatThatOpensOrClosesStillReachesThePanel() throws {
        let store = try Self.store(workspaces: 10, terminals: 2)
        let machine = SidebarPriorityMachine(name: "gpu-box", store: store)
        let fired = Fired()
        _ = withObservationTracking { machine.lanes() } onChange: { fired.fire() }
        store.apply(.tabAdded(TabDelta(workspace: 5, screen: 5, pane: 5, surface: 90_000_003, index: nil, entity: Self.chat(90_000_003, session: "s-new"))))
        #expect(fired.fired, "a chat that opens on the machine is a row the panel must hear")
        #expect(Set(machine.lanes().map(\.id)) == ["s-asks", "s-idle", "s-new"])
        #expect(machine.tab(showing: "s-new") == store.tab(surface: 90_000_003)?.id)
        store.apply(.tabClosed(TabDelta(workspace: 1, screen: 1, pane: 1, surface: 90_000_001, index: nil, entity: Self.chat(90_000_001, session: "s-asks"))))
        #expect(Set(machine.lanes().map(\.id)) == ["s-idle", "s-new"])
        #expect(machine.tab(showing: "s-asks") == nil)
    }

    static func microseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1e6 + Double(duration.components.attoseconds) / 1e12
    }

    /// The panel's per-machine cost against the machine's size: BENCH lines at 10, 100 and 1000 workspaces of 4
    /// terminals and 2 chats (lanes, then a row's open looking up its tab).
    @Test func benchLanesAndTabLookupAtTenAHundredAndAThousandWorkspaces() throws {
        var medians: [Int: Double] = [:]
        for workspaces in [10, 100, 1_000] {
            let machine = SidebarPriorityMachine(name: "gpu-box", store: try Self.store(workspaces: workspaces, terminals: 4))
            var samples: [Double] = []
            for _ in 0..<101 {
                let start = ContinuousClock.now
                let lanes = machine.lanes()
                let tab = machine.tab(showing: "s-idle")
                samples.append(Self.microseconds(ContinuousClock.now - start))
                #expect(lanes.count == 2 && tab != nil)
            }
            medians[workspaces] = samples.sorted()[samples.count / 2]
            print("BENCH H13 priority-machine workspaces=\(workspaces) tabs=\(workspaces * 4 + 2) median_us=\(String(format: "%.2f", medians[workspaces] ?? 0))")
        }
        print("BENCH H13 priority-machine ratio_1000_over_10=\(String(format: "%.1f", (medians[1_000] ?? 0) / max(medians[10] ?? 1, 0.001)))")
    }
}
