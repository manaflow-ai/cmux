import CmuxNextAgentActivity
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextSidebar
import Darwin
import Foundation
import Observation
import Testing
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp

/// Lawrence 2026-10-21: "i feel like sidebar got a lot laggier recently." Each agent's step (the
/// row's "Now:" line, `sidebar.nowLine`), state and chip come from its acpmux lane, and a working
/// agent changes its lane many times a second. One lane's change maps that lane's row again, never
/// every row that shows a chat: the cost of an agent event does not grow with the workspaces
/// (sidebar-lag-DESIGN.md). Prints one `SIDEBAR-LANE-TICK` line per size.
@MainActor @Suite(.serialized) struct SidebarLaneTickCostTests {
    static let host = "install:lane-tick"

    @MainActor final class Fixture {
        let store = DaemonStore()
        let turns = AgentTurnStateStore()
        let lanes = AgentLaneStore()
        let model = SidebarModel(sections: [])
        let rows: SidebarRows
        final class Pending { var work: [@MainActor @Sendable () -> Void] = [] }
        let pending = Pending()
        let feed: SidebarRowFeed
        /// Rows mapped since the last read.
        var mapped = 0

        init(count: Int) {
            rows = SidebarRows(model: model, document: { nil })
            var workspaces: [WorkspaceSnapshot] = []
            for i in 0..<count {
                let id = UInt64(i + 1)
                var tab = TabSnapshot(surface: SurfaceID(rawValue: id), kind: .conversation, cwd: nil)
                tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: SidebarLaneTickCostTests.host, session: "s-\(i)", harness: "claude"))
                let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: [tab])
                let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
                workspaces.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "Agent workspace \(i)", screens: [screen]))
            }
            store.apply(snapshot: DaemonTree(workspaces: workspaces))
            turns.localHost = SidebarLaneTickCostTests.host
            var all: [String: AgentActivityLane] = [:]
            for i in 0..<count { all["s-\(i)"] = Self.lane(i, step: "Reading file 0") }
            lanes.lanes = all
            feed = SidebarRowFeed(schedule: { [pending] in pending.work.append($0) })
            feed.onChange = { [rows] in rows.patch($0) }
            // The feed's row source, each map counted (as the app's `laneRowSource` composes it).
            let feed = feed
            let counting: SidebarMapping.RowSource = { [unowned self] workspace, machine, make in
                feed.row(SidebarWorkspaceID(workspace.id), machine: machine) { self.mapped += 1; return make() }
            }
            feed.beginPass(inputs: 0)
            let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local),
                                                          rowSource: SidebarLaneStatus.applying(counting, lanes: lanes, turns: turns))
            rows.show(feed.fill(sections))
            mapped = 0
        }

        static func lane(_ i: Int, step: String) -> AgentActivityLane {
            AgentActivityLane(id: "s-\(i)", name: "s-\(i)", title: "Agent \(i)", peer: nil, parent: nil, state: .working,
                              since: Date(timeIntervalSince1970: 1_000), error: nil, harness: "claude", step: step,
                              cwd: "/tmp/feature-\(i)")
        }

        /// One agent event: lane `i` says a new step; the frame's flush runs.
        func step(_ i: Int, _ text: String) {
            lanes.lanes["s-\(i)"] = Self.lane(i, step: text)
            let work = pending.work
            pending.work.removeAll()
            work.forEach { $0() }
        }
    }

    static func withLaneTunables(_ body: () throws -> Void) rethrows {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let keys = [SidebarTunables.laneStatus.key, SidebarTunables.rowStatus.key, SidebarTunables.nowLine.key]
        for key in keys { TunableStore.shared.set(key, .bool(true)) }
        defer { for key in keys { TunableStore.shared.set(key, nil) } }
        try body()
    }

    static func cpu() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) * 1_000 + Double(ts.tv_nsec) / 1e6
    }

    /// One working agent's new step maps its own row again and shows it as its "Now:" line; the
    /// other rows, whose lanes did not change, are not mapped.
    @Test func oneAgentsStepMapsOnlyItsRow() throws {
        try Self.withLaneTunables {
            let fixture = Fixture(count: 150)
            fixture.step(7, "Editing SidebarListView.swift")
            #expect(fixture.mapped == 1, "one lane's step mapped \(fixture.mapped) rows of 150")
            let row = fixture.model.sections.flatMap(\.workspaces).first { $0.title == "Agent workspace 7" }
            #expect(row?.agentStep == "Editing SidebarListView.swift")
        }
    }

    /// The pull request badges' pass reads each session's links: a new step leaves them alone, a
    /// new folder tells them.
    @Test func aStepLeavesTheLaneLinksAlone() {
        let lanes = AgentLaneStore()
        lanes.lanes = ["s-1": Fixture.lane(1, step: "Reading")]
        nonisolated final class Told: @unchecked Sendable { var value = false } // written once by the tracking callback, read after on this thread
        let told = Told()
        withObservationTracking { _ = lanes.links("s-1") } onChange: { told.value = true }
        lanes.lanes["s-1"] = Fixture.lane(1, step: "Editing")
        #expect(!told.value, "a new step told the links' reader")
        #expect(lanes.lane("s-1")?.step == "Editing")
        let moved = AgentActivityLane(id: "s-1", name: "s-1", title: "Agent 1", peer: nil, parent: nil, state: .working,
                                      since: nil, error: nil, step: "Editing", cwd: "/tmp/elsewhere")
        lanes.lanes["s-1"] = moved
        #expect(told.value, "a new folder did not tell the links' reader")
    }

    /// Not a check: main-thread CPU per agent event (lane write, row maps, patch) at 150 and 500.
    @Test func laneEventCostByWorkspaceCount() throws {
        try Self.withLaneTunables {
            for count in [150, 500] {
                let fixture = Fixture(count: count)
                var costs: [Double] = []
                var mapped = 0
                for k in 0..<300 {
                    let t0 = Self.cpu()
                    fixture.step((k * 7) % count, "Editing file \(k)")
                    costs.append(Self.cpu() - t0)
                    mapped += fixture.mapped
                    fixture.mapped = 0
                }
                let sorted = costs.sorted()
                func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
                print(String(format: "SIDEBAR-LANE-TICK n=%d events=%d | cpu_ms p50 %.3f p95 %.3f max %.3f | rows mapped/event %.1f",
                             count, costs.count, p(0.5), p(0.95), sorted.last ?? 0, Double(mapped) / Double(costs.count)))
            }
        }
    }
}
