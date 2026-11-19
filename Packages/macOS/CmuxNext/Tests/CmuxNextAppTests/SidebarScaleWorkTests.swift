import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The sidebar's cost of one peer session's change must not grow with the sessions attached (goal
/// sessions-2000-attached; Leo: "2,000 live acpmux sessions on GCP and Freestyle VMs are all attached to
/// cosmic-gray and visible and steerable from Leo's app there"): at 2,000 sessions within 1.2x of 50.
///
/// At N = 50, 200 and 2,000 peer sessions over eight machines this sends one `_acpmux/session_changed` of one
/// peer session, then one follow reply with one changed row, and after each runs what the readers do for it:
/// the machines' groups (`RemoteMachinesSidebar.rebuild`), the Dock menu's chats (`DockMenuController`) and the
/// band's transient rows (`SidebarModel.placingTransientItems`). `ScaleWork` counts the work: sessions walked,
/// sets built over every session, whole rebuilds, band rows visited and whole lists laid over the stores.
/// A third scenario shows every chat of one machine (its pages opened) and counts the band rows visited per row
/// shown. Each prints one `SIDEBAR-SCALE {json}` line, which the `sidebar-scale` bench reads
/// (scripts/bench/benches/sidebar_scale.py). Run it on a fleet Mac:
/// `cmux-ci run --class light --script scripts/ci/package-test-lane.sh --ref SHA --arg=suite
/// --arg=Packages/macOS/CmuxNext --arg=SidebarScaleWorkTests`.
@MainActor
@Suite(.serialized)
struct SidebarScaleWorkTests {
    static let sizes = [50, 200, 2000]
    static let machines = 8
    static let allowed = 1.2

    @MainActor final class DockHost: DockMenuHost {
        func dockMenuHarnesses() async -> [AcpmuxHarnessRow] { [] }
        func dockMenuMachines() async -> [AgentChatDestinations.Destination] { [] }
        var dockMenuWindow: DockMenuWindow { .pane }
        func dockMenuReopenWindow() {}
        func dockMenuNewChat(_ arguments: [String: ActionValue]) {}
        func dockMenuOpenChat(_ id: String) throws {}
        func dockMenuRefuse(_ reason: String) {}
    }

    /// One attached app: the watch feed over its stores and the readers of its lanes.
    @MainActor final class Scene {
        let turns = AgentTurnStateStore()
        let lanes = AgentLaneStore()
        let feed: AgentTurnStateFeed
        let sidebar: RemoteMachinesSidebar
        let dock: DockMenuController
        let model = SidebarModel()
        let host = DockHost()
        let section = LayoutSection(id: LayoutSectionID("sec_top"), showsTitle: false, region: .top, look: .builtIn,
                                    items: [LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)])
        let count: Int
        var seq: UInt64 = 1
        let expandedBefore: Set<String>

        init(count: Int) throws {
            self.count = count
            turns.localHost = "install:scale"
            feed = AgentTurnStateFeed(socketPath: "/nonexistent/sidebar-scale.sock", turns: turns, lanes: lanes)
            sidebar = RemoteMachinesSidebar(lanes: lanes)
            dock = DockMenuController(lanes: lanes, marks: AgentPriorityMarks(defaults: nil), host: host)
            expandedBefore = sidebar.expanded
            feed.handle(.initialized(follows: true))
            feed.handle(try Self.message(["jsonrpc": "2.0", "id": 2, "result": [
                "listSeq": 1, "listEpoch": "run", "sessions": (0..<count).map { Self.summary($0, working: false) },
            ]]))
            // The usage read answers after the page: every chat's numbers.
            feed.handle(try Self.message(["jsonrpc": "2.0", "id": 3, "result": [
                "sessions": (0..<count).map { Self.summary($0, working: false) },
            ]]))
            sidebar.bind(host: RemoteMachinesSidebar.Host(peers: { nil }, older: { _, _ in nil }, displayName: { _ in nil },
                                                          open: { _ in }))
            sidebar.expanded = ["vm0"]
        }

        func stop() {
            sidebar.stop()
            sidebar.expanded = expandedBefore
        }

        static func peer(_ i: Int) -> String { "vm\(i % SidebarScaleWorkTests.machines)" }

        static func summary(_ i: Int, working: Bool, at ms: Double = 1_700_000_000_000) -> [String: Any] {
            [
                "sessionId": "s\(i)", "peer": peer(i), "name": "\(peer(i))/chat-\(i)", "title": "Chat \(i)",
                "indicator": working ? "working" : "idle", "harness": "codex",
                "lane": ["state": working ? "working" : "idle", "since": ms - Double(i) * 1000],
                "updatedMs": ms - Double(i) * 1000, "createdMs": ms - Double(i) * 2000,
                "usageStats": ["contextTokens": 1000 + i, "contextWindow": 200_000],
            ]
        }

        static func message(_ object: [String: Any]) throws -> AgentTurnStateFeed.Message {
            try #require(AgentTurnStateFeed.Message(line: try JSONSerialization.data(withJSONObject: object)))
        }

        /// One peer session's push: it starts working.
        func change(_ i: Int) throws -> AgentTurnStateFeed.Message {
            seq += 1
            return try Self.message(["jsonrpc": "2.0", "method": "_acpmux/session_changed", "params": [
                "sessionId": "s\(i)", "peer": Self.peer(i), "listSeq": seq,
                "session": Self.summary(i, working: true, at: 1_800_000_000_000 + Double(seq)),
            ]])
        }

        /// A follow reply (after a lag) with one changed row.
        func follow(_ i: Int) throws -> AgentTurnStateFeed.Message {
            seq += 1
            return try Self.message(["jsonrpc": "2.0", "id": 2, "result": [
                "follow": true, "listSeq": seq, "listEpoch": "run", "more": false,
                "sessions": [Self.summary(i, working: true, at: 1_800_000_000_000 + Double(seq))], "gone": [],
            ]])
        }

        /// What the readers do after a change: the groups, the Dock menu, the band's rows.
        func readersRun() {
            sidebar.rebuild()
            dock.refreshChats()
            model.transientTopItems = sidebar.rows()
            _ = model.placingTransientItems(in: [section])
        }

        func measure(_ message: AgentTurnStateFeed.Message) -> ScaleWork {
            let work = ScaleWork()
            ScaleWork.$current.withValue(work) {
                feed.handle(message)
                readersRun()
            }
            return work
        }
    }

    static func line(_ op: String, _ n: Int, _ work: ScaleWork, rows: Int? = nil) -> String {
        var fields: [String: Any] = ["op": op, "n": n, "total": work.total]
        for kind in ScaleWork.Kind.allCases { fields[kind.rawValue] = work[kind] }
        if let rows { fields["rows"] = rows }
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return "SIDEBAR-SCALE " + (String(data: data, encoding: .utf8) ?? "{}")
    }

    @Test func onePeerChangeCostsTheSameAt2000SessionsAsAt50() throws {
        var totals: [String: [Int: Int]] = [:]
        for n in Self.sizes {
            let scene = try Scene(count: n)
            defer { scene.stop() }
            // Warm: the first rebuild and the cells every reader made.
            scene.feed.handle(try scene.change(3))
            scene.readersRun()
            scene.feed.handle(try scene.follow(4))
            scene.readersRun()
            for (op, message) in [("change", try scene.change(8)), ("follow", try scene.follow(16))] {
                let work = scene.measure(message)
                print(Self.line(op, n, work))
                totals[op, default: [:]][n] = work.total
            }
            #expect(scene.lanes.lanes["s8"]?.state == .working, "the change reached the lanes")
            #expect(scene.lanes.lanes["s16"]?.state == .working, "the follow reached the lanes")
            // vm0's two working chats: s8 changed at listSeq 4 (since 1.8e12 + 4 - 8,000 ms) and s16 followed at 5
            // (since 1.8e12 + 5 - 16,000 ms). The newest `since` leads (`RemoteMachinesSidebar.newer`): s8, then s16.
            // The groups moved in place must equal a whole build of the same lanes.
            let vm0 = scene.sidebar.machines.first { $0.peer == "vm0" }?.chats.map(\.id)
            #expect(vm0.map { Array($0.prefix(2)) } == ["s8", "s16"], "the changed chats lead their machine's group, newest first")
            #expect(vm0 == RemoteMachinesSidebar.machines(lanes: scene.lanes.lanes.values, peers: nil)
                .first { $0.peer == "vm0" }?.chats.map(\.id), "the groups moved in place are the whole build's")
        }
        for (op, byN) in totals.sorted(by: { $0.key < $1.key }) {
            let (small, large) = (byN[Self.sizes[0]] ?? 0, byN[Self.sizes.last ?? 0] ?? 0)
            let ratio = Double(large) / Double(max(small, 1))
            print("SIDEBAR-SCALE-RATIO {\"op\":\"\(op)\",\"ratio\":\(ratio)}")
            #expect(ratio <= Self.allowed, "\(op): \(large) units at \(Self.sizes.last ?? 0) sessions, \(small) at \(Self.sizes[0])")
        }
    }

    /// Every chat of one machine shown (its Show More pages opened): the band's placing visits each row a
    /// bounded number of times, however many rows show.
    @Test func placingTheBandsRowsCostsTheSamePerRowAt2000AsAt50() throws {
        var perRow: [Int: Double] = [:]
        for n in Self.sizes {
            let scene = try Scene(count: n * Self.machines)
            defer { scene.stop() }
            scene.sidebar.pages["vm0"] = n / RemoteMachinesSidebar.pageSize + 1
            scene.sidebar.rebuild()
            scene.model.transientTopItems = scene.sidebar.rows()
            let rows = scene.model.transientTopItems.count
            let work = ScaleWork()
            ScaleWork.$current.withValue(work) { _ = scene.model.placingTransientItems(in: [scene.section]) }
            print(Self.line("band", n, work, rows: rows))
            perRow[n] = Double(work[.bandRows]) / Double(max(rows, 1))
        }
        let ratio = (perRow[Self.sizes.last ?? 0] ?? 0) / max(perRow[Self.sizes[0]] ?? 1, 1)
        print("SIDEBAR-SCALE-RATIO {\"op\":\"band\",\"ratio\":\(ratio)}")
        #expect(ratio <= Self.allowed, "band rows visited per row shown: \(perRow)")
    }

    /// The scene places what the full list would: every row once, in order.
    @Test func theBandsRowsKeepTheirOrder() throws {
        let scene = try Scene(count: 40)
        defer { scene.stop() }
        scene.sidebar.rebuild()
        scene.model.transientTopItems = scene.sidebar.rows()
        let placed = scene.model.placingTransientItems(in: [scene.section]).flatMap(\.items).map(\.id)
        #expect(placed == [LayoutItemID("itm_home")] + scene.model.transientTopItems.map(\.item.id))
    }
}
