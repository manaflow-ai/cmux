import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextKeepAwake
@testable import CmuxNextSettings
import Foundation
import Observation
import Testing

/// Design audit 2026-11-18, finding 7: a push of an acpmux peer's session wrote the peer's state into this
/// Mac's record of the session id. So each peer turn end walked every tab of every workspace on main
/// (O(1,600 tabs) per turn end of any of ~30 machines), and `hasWorkingSession` held this Mac awake while
/// any other machine's agent worked. A peer push now writes only that peer's row; a turn end reaches only
/// the chat's own tabs, through the store's index by session id; the working count is this Mac's sessions.
@MainActor @Suite(.serialized)
struct PeerTurnEndTests {
    static let peerSession = "peer-turn-end-s1"

    /// A `_acpmux/session_changed` of `session` as peer `peer`'s row on this Mac's acpmux.
    static func peerChange(_ peer: String, session: String = peerSession, indicator: String) throws -> AgentTurnStateFeed.Message {
        let line = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"\#(session)","peer":"\#(peer)","session":{"sessionId":"\#(session)","indicator":"\#(indicator)","peer":"\#(peer)"}}}"#
        return try #require(AgentTurnStateFeed.Message(line: Data(line.utf8)))
    }

    /// A `_acpmux/session_changed` of this Mac's own session `session`.
    static func localChange(_ session: String, indicator: String) throws -> AgentTurnStateFeed.Message {
        let line = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"\#(session)","session":{"sessionId":"\#(session)","indicator":"\#(indicator)"}}}"#
        return try #require(AgentTurnStateFeed.Message(line: Data(line.utf8)))
    }

    /// `workspaces` workspaces of `tabsEach` agent chat tabs: the first tab shows the peer's chat, every other one
    /// a chat of this Mac.
    static func session(workspaces: Int, tabsEach: Int) -> DaemonTree {
        var trees: [WorkspaceSnapshot] = []
        var surface: UInt64 = 0
        for w in 0..<workspaces {
            var tabs: [TabSnapshot] = []
            for t in 0..<tabsEach {
                surface += 1
                var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, cwd: nil)
                let peer = w == 0 && t == 0
                tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(
                    host: peer ? "registry:peer-turn-end" : "install:peer-turn-end", hostName: peer ? "lab" : nil,
                    session: peer ? peerSession : "local-\(surface)", harness: "claude"))
                tabs.append(tab)
            }
            let id = UInt64(w + 1)
            let pane = PaneSnapshot(id: PaneID(rawValue: id), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: id), layout: .leaf(PaneID(rawValue: id)), panes: [pane])
            trees.append(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id), key: nil, name: "w\(w)", screens: [screen]))
        }
        return DaemonTree(workspaces: trees)
    }

    final class Flag: @unchecked Sendable { var raised = false }

    /// The detector: a peer's turn end reads the tabs of its own session and no other. Base walked every
    /// tab of every workspace (it read each tab's `agentSession`), so a change of any other tab's facts
    /// after the turn end woke what it read.
    @Test func aPeerTurnEndReadsNoTabOutsideItsOwnSession() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.apply(snapshot: Self.session(workspaces: 20, tabsEach: 10))
        let tabs = store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
        let target = try #require(tabs.first { $0.agentSession?.session == Self.peerSession })
        let service = NotificationCenterService()
        service.services = services
        let turns = AgentTurnStateStore()
        turns.localHost = "install:peer-turn-end"
        turns.onTurnEnded = { [weak service] in service?.agentTurnEnded(session: $0) }
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/peer-turn-end.sock", turns: turns, lanes: AgentLaneStore())
        let design = DesignSettings.shared
        let before = design.attention
        defer { design.attention = before }
        design.attention = AttentionSettings()
        design.attention.agentChatRing = .ring

        feed.handle(try Self.peerChange("lab", indicator: "working"))
        let end = try Self.peerChange("lab", indicator: "idle")
        let woke = Flag()
        withObservationTracking {
            feed.handle(end)
        } onChange: {
            woke.raised = true
        }
        #expect(service.agentFinished[target.id] != nil, "the peer chat's tab did not ring when its turn ended")
        // Every fact a walk of the tabs reads, changed on every tab but the peer chat's.
        for tab in tabs where tab !== target { tab.formerLocalHosts = ["install:former": "install:peer-turn-end"] }
        #expect(!woke.raised, "a peer's turn end read tabs outside its own session (a walk of every tab of every workspace)")
        #expect(turns.state(for: AgentSessionRef(host: "install:peer-turn-end", session: Self.peerSession)) == nil,
                "a peer's push wrote this Mac's state of the session id")
    }

    /// A chat of this Mac rings through the same index, and its turn end reads only its own tabs too.
}
