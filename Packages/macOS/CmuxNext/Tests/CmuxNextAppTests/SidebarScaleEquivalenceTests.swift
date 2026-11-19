import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The per-session paths `SidebarScaleWorkTests` counts give what the whole rebuilds gave: a follow's rows laid
/// alone, the machines' groups moved one chat at a time, the Dock menu from its kept order, the band's rows
/// placed in one pass.
@MainActor
@Suite(.serialized)
struct SidebarScaleEquivalenceTests {
    struct Rng {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static func lane(_ i: Int, peer: String?, state: AgentActivityLane.State, since: Double, unread: Bool = false,
                     updated: Double? = nil) -> AgentActivityLane {
        AgentActivityLane(id: "s\(i)", name: (peer ?? "mac") + "/chat-\(i)", title: "Chat \(i)", peer: peer, parent: nil, state: state,
                          since: Date(timeIntervalSince1970: since), error: nil, harness: "codex", unread: unread,
                          updatedAt: updated.map { Date(timeIntervalSince1970: $0) })
    }

    static let states: [AgentActivityLane.State] = [.idle, .working, .input]

    /// Random single changes, with the groups updated after each burst: always the whole build's groups.
    @Test func theGroupsMovedOneChatAtATimeAreTheWholeBuilds() {
        let lanes = AgentLaneStore()
        var rng = Rng(state: 7)
        var all: [String: AgentActivityLane] = [:]
        for i in 0..<120 { all["s\(i)"] = Self.lane(i, peer: i % 9 == 0 ? nil : "vm\(i % 4)", state: .idle, since: Double(i)) }
        lanes.lanes = all
        let sidebar = RemoteMachinesSidebar(lanes: lanes)
        sidebar.bind(host: RemoteMachinesSidebar.Host(peers: { nil }, older: { _, _ in nil }, displayName: { _ in nil }, open: { _ in }))
        defer { sidebar.stop() }
        for round in 0..<60 {
            for _ in 0..<(1 + rng.next(5)) {
                let i = rng.next(140)
                switch rng.next(6) {
                case 0: lanes.set("s\(i)", nil)
                case 1: lanes.set("s\(i)", Self.lane(i, peer: "vm\(rng.next(5))", state: Self.states[rng.next(3)], since: Double(rng.next(400))))
                default: lanes.set("s\(i)", Self.lane(i, peer: "vm\(i % 4)", state: Self.states[rng.next(3)], since: Double(1000 + round * 10 + rng.next(9))))
                }
            }
            sidebar.rebuild()
            let whole = RemoteMachinesSidebar.machines(lanes: lanes.lanes.values, peers: nil)
            #expect(sidebar.machines == whole, "round \(round)")
        }
    }

    @Test func theDockMenuFromItsKeptOrderIsTheWholeMake() {
        var rng = Rng(state: 11)
        var all: [String: AgentActivityLane] = [:]
        var order = DockMenuChats.Order()
        var marks = AgentPriorityMarks.State()
        for round in 0..<200 {
            let i = rng.next(80)
            let lane = rng.next(7) == 0 ? nil
                : Self.lane(i, peer: "vm\(i % 3)", state: Self.states[rng.next(3)], since: Double(rng.next(50)), unread: rng.next(3) == 0,
                            updated: rng.next(4) == 0 ? nil : Double(rng.next(500)))
            all["s\(i)"] = lane
            order.update("s\(i)", lane)
            if rng.next(10) == 0 { marks.archived.insert("s\(rng.next(80))") }
            let unread = Set(all.values.filter(\.unread).map(\.id))
            let now = Date(timeIntervalSince1970: 1_000)
            #expect(DockMenuChats.make(ordered: order, lanes: all, unread: unread, marks: marks, now: now)
                == DockMenuChats.make(lanes: all.values, marks: marks, now: now), "round \(round)")
        }
        #expect(order.keys.map(\.id) == DockMenuChats.Order(all.values).keys.map(\.id))
    }

    /// The band's rows as the old placing put them: each item inserted right after its anchor in the list
    /// placed so far.
    static func placedTheOldWay(_ transients: [SidebarTransientItem], in sections: [LayoutSection], anchoredOnly: Bool) -> [LayoutSection] {
        var placed = sections
        var loose: [LayoutItem] = []
        for transient in transients {
            var found: (Int, Int)?
            search: for ref in transient.after {
                for (s, section) in placed.enumerated() {
                    if let i = section.items.firstIndex(where: { $0.ref == ref }) {
                        found = (s, i)
                        break search
                    }
                }
            }
            guard let (s, i) = found else {
                if !transient.anchoredOnly { loose.append(transient.item) }
                continue
            }
            placed[s].items.insert(transient.item, at: i + 1)
        }
        guard !anchoredOnly, !loose.isEmpty else { return placed }
        return [LayoutSection(id: LayoutSectionID(LayoutItemID.transientPrefix + "top"), showsTitle: false,
                              region: .top, look: .builtIn, items: loose)] + placed
    }

    @Test func theBandsRowsPlacedInOnePassAreTheOldPlacing() {
        var rng = Rng(state: 3)
        for round in 0..<100 {
            let sections = (0..<(1 + rng.next(3))).map { s in
                LayoutSection(id: LayoutSectionID("sec\(s)"), region: .top, items: (0..<rng.next(5)).map { i in
                    LayoutItem(id: LayoutItemID("itm\(s)-\(i)"), ref: .app("app\(s)-\(i)"))
                })
            }
            let shown = sections.flatMap(\.items).map(\.ref)
            var refs: [LayoutItemRef] = shown + [.app("missing")]
            var transients: [SidebarTransientItem] = []
            for k in 0..<rng.next(30) {
                let after = (0..<rng.next(3)).map { _ in refs[rng.next(refs.count)] }
                let item = SidebarTransientItem(id: LayoutItemID(LayoutItemID.transientPrefix + "t\(k)"),
                                                info: SidebarItemInfo(title: "t\(k)", symbol: "circle"), after: after,
                                                anchoredOnly: rng.next(4) == 0)
                transients.append(item)
                refs.append(item.item.ref)
            }
            let model = SidebarModel()
            model.transientTopItems = transients
            for anchoredOnly in [false, true] {
                let now = model.placingTransientItems(in: sections, anchoredOnly: anchoredOnly)
                let old = Self.placedTheOldWay(transients, in: sections, anchoredOnly: anchoredOnly)
                #expect(now == old, "round \(round), anchoredOnly \(anchoredOnly)")
            }
        }
    }

    static func message(_ object: [String: Any]) throws -> AgentTurnStateFeed.Message {
        try #require(AgentTurnStateFeed.Message(line: try JSONSerialization.data(withJSONObject: object)))
    }

    static func summary(_ id: String, _ indicator: String, title: String, peer: String? = nil, lane: String = "idle") -> [String: Any] {
        var row: [String: Any] = ["sessionId": id, "indicator": indicator, "title": title, "name": id, "lane": ["state": lane, "since": 1000]]
        if let peer { row["peer"] = peer }
        return row
    }

    /// A follow's rows written alone leave the stores as a whole list of the same sessions does.
    @Test func aFollowsRowsWrittenAloneAreTheWholeLists() throws {
        let host = "install:follow-rows"
        let start = [Self.summary("a", "working", title: "A", lane: "working"), Self.summary("b", "input", title: "B", lane: "input"),
                     Self.summary("c", "working", title: "C", peer: "box"), Self.summary("d", "idle", title: "D")]
        let after = [Self.summary("a", "input", title: "A2", lane: "input"), Self.summary("d", "idle", title: "D"),
                     Self.summary("e", "working", title: "E", lane: "working")]
        func scene(_ pages: [[String: Any]]) throws -> (AgentTurnStateStore, AgentLaneStore, AgentTurnStateFeed) {
            let turns = AgentTurnStateStore()
            turns.localHost = host
            let lanes = AgentLaneStore()
            let feed = AgentTurnStateFeed(socketPath: "/nonexistent/follow-rows.sock", turns: turns, lanes: lanes)
            feed.handle(.initialized(follows: true))
            for page in pages { feed.handle(try Self.message(["jsonrpc": "2.0", "id": 2, "result": page])) }
            return (turns, lanes, feed)
        }
        let (followed, followedLanes, _) = try scene([
            ["listSeq": 4, "listEpoch": "run", "sessions": start],
            ["follow": true, "listSeq": 9, "listEpoch": "run", "more": false,
             "sessions": [Self.summary("a", "input", title: "A2", lane: "input"), Self.summary("e", "working", title: "E", lane: "working")],
             "gone": [["sessionId": "b"], ["sessionId": "c", "peer": "box"]]],
        ])
        let (whole, wholeLanes, _) = try scene([["listSeq": 9, "listEpoch": "run", "sessions": after]])
        #expect(followedLanes.lanes == wholeLanes.lanes)
        for id in ["a", "b", "c", "d", "e"] {
            let ref = AgentSessionRef(host: host, session: id)
            #expect(followed.state(for: ref) == whole.state(for: ref), "\(id)")
            #expect(followed.title(for: ref) == whole.title(for: ref), "\(id)")
        }
    }

    @Test func theJournalNamesTheChangedSessionsAndAWholeWriteForgetsThem() {
        let lanes = AgentLaneStore()
        let start = lanes.revision
        lanes.set("a", Self.lane(1, peer: "vm", state: .idle, since: 1))
        lanes.set("b", Self.lane(2, peer: "vm", state: .idle, since: 1))
        lanes.set("a", Self.lane(1, peer: "vm", state: .working, since: 2))
        #expect(lanes.changes(since: start) == ["a", "b"])
        let mid = lanes.revision
        lanes.set("b", Self.lane(2, peer: "vm", state: .idle, since: 1)) // the same lane: no change
        #expect(lanes.changes(since: mid) == [])
        lanes.lanes = [:]
        #expect(lanes.changes(since: mid) == nil, "a whole write: rebuild")
        #expect(lanes.changes(since: lanes.revision) == [])
    }
}
