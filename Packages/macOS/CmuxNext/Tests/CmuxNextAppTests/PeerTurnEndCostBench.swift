import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// Design audit 2026-11-18, finding 7: main-thread time of one acpmux peer's turn end (its
/// `_acpmux/session_changed` from working to idle, as the watch feed handles it on main) in a session of
/// 1,600 tabs, with 10,000 sessions listed and 30 peers. Prints one `PEER-TURN-END` line. Off unless
/// `CMUX_PEER_TURN_END_BENCH=1` (scripts/measure/swift-test-bench.sh `enable=`); built only from APIs base has,
/// so `restore_from=` measures base's sources with this same harness.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PEER_TURN_END_BENCH"] == "1"))
struct PeerTurnEndCostBench {
    static let tabs = 1_600, tabsPerWorkspace = 10, sessions = 10_000, peers = 30, peerRows = 100, rounds = 2_000

    @Test func peerTurnEndMainThreadTime() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        // 1,600 agent chat tabs: one per peer shows that peer's first chat, every other one a chat of this Mac.
        var workspaces: [WorkspaceSnapshot] = []
        var surface: UInt64 = 0
        for w in 0..<(Self.tabs / Self.tabsPerWorkspace) {
            var tabs: [TabSnapshot] = []
            for _ in 0..<Self.tabsPerWorkspace {
                surface += 1
                var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, cwd: nil)
                let index = Int(surface) - 1
                tab.conversation = ConversationTabRef(agentSession: index < Self.peers
                    ? AgentSessionRef(host: "registry:peer-\(index)", hostName: "peer-\(index)", session: "peer-\(index)-0", harness: "claude")
                    : AgentSessionRef(host: "install:peer-bench", session: "local-\(index)", harness: "claude"))
                tabs.append(tab)
            }
            let id = UInt64(w + 1)
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            workspaces.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(w)", screens: [screen]))
        }
        store.apply(snapshot: DaemonTree(workspaces: workspaces))

        let service = NotificationCenterService()
        service.services = services
        let turns = AgentTurnStateStore()
        turns.localHost = "install:peer-bench"
        turns.onTurnEnded = { [weak service] in service?.agentTurnEnded($0) }
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/peer-turn-end-bench.sock", turns: turns, lanes: AgentLaneStore())
        let design = DesignSettings.shared
        let before = design.attention
        defer { design.attention = before }
        design.attention = AttentionSettings()
        design.attention.agentChatRing = .ring

        // 10,000 sessions: 30 peers' 100 rows each, the rest this Mac's (a quarter of them working).
        var summaries: [String] = []
        for p in 0..<Self.peers {
            for k in 0..<Self.peerRows { summaries.append(#"{"sessionId":"peer-\#(p)-\#(k)","indicator":"working","peer":"peer-\#(p)"}"#) }
        }
        for i in 0..<(Self.sessions - Self.peers * Self.peerRows) {
            summaries.append(#"{"sessionId":"local-\#(i)","indicator":"\#(i % 4 == 0 ? "working" : "idle")"}"#)
        }
        let page = #"{"jsonrpc":"2.0","id":2,"result":{"sessions":[\#(summaries.joined(separator: ","))]}}"#
        feed.handle(try #require(AgentTurnStateFeed.Message(line: Data(page.utf8))))

        func change(_ p: Int, _ k: Int, _ indicator: String) throws -> AgentTurnStateFeed.Message {
            let line = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"peer-\#(p)-\#(k)","peer":"peer-\#(p)","session":{"sessionId":"peer-\#(p)-\#(k)","indicator":"\#(indicator)","peer":"peer-\#(p)"}}}"#
            return try #require(AgentTurnStateFeed.Message(line: Data(line.utf8)))
        }
        // Decoded off the clock, as the feed decodes off main; each round one peer's chat starts and ends a turn
        // (every tenth the chat a tab shows, so the ring's own work is in the numbers).
        var rounds: [(start: AgentTurnStateFeed.Message, end: AgentTurnStateFeed.Message)] = []
        for r in 0..<Self.rounds {
            let p = r % Self.peers, k = r % 10 == 0 ? 0 : 1 + (r / Self.peers) % (Self.peerRows - 1)
            rounds.append((try change(p, k, "working"), try change(p, k, "idle")))
        }
        let clock = ContinuousClock()
        var samples: [Double] = []
        samples.reserveCapacity(Self.rounds)
        for (start, end) in rounds {
            feed.handle(start)
            let began = clock.now
            feed.handle(end)
            let spent = clock.now - began
            samples.append(Double(spent.components.attoseconds) / 1e12 + Double(spent.components.seconds) * 1e6)
        }
        samples.sort()
        let median = samples[samples.count / 2], p95 = samples[samples.count * 95 / 100], p99 = samples[samples.count * 99 / 100]
        let mean = samples.reduce(0, +) / Double(samples.count)
        let rung = service.agentFinished.count
        print(String(format: "PEER-TURN-END tabs=%ld sessions=%ld peers=%ld rounds=%ld median_us=%.1f p95_us=%.1f p99_us=%.1f mean_us=%.1f rung_tabs=%ld",
                     store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).count, Self.sessions, Self.peers, Self.rounds,
                     median, p95, p99, mean, rung))
        #expect(rung > 0, "no peer chat's tab rang: the bench did not reach the ring")
    }
}
