import AppKit
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextRemote
import Foundation
import Testing

/// Leo (2026-11-06): "why would it be doing anything inside a chat if the chat itself is
/// thinking?" A chat of another machine has no turn state of this Mac's, so it rang while it
/// worked. This Mac's acpmux has that chat's row from its acpmux peer (`peer`): when that peer is
/// the chat's machine and the row is live, its working state stops the ring as a local chat's does.
@MainActor @Suite(.serialized)
struct RemoteThinkingChatRingTests {
    static let session = "remote-thinking-s1"

    /// A `_acpmux/session_changed` of `session` as peer `peer`'s row on this Mac's acpmux.
    static func peerChange(_ peer: String, indicator: String, stale: Bool = false) throws -> AgentTurnStateFeed.Message {
        let line = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"\#(session)","peer":"\#(peer)","session":{"sessionId":"\#(session)","indicator":"\#(indicator)","peer":"\#(peer)","stale":\#(stale)}}}"#
        return try #require(AgentTurnStateFeed.Message(line: Data(line.utf8)))
    }

    @Test func aRemoteChatThatIsThinkingDrawsNoRing() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@lab.tail1.ts.net")).named("lab")
        let ssh = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                    paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-remote-thinking-ring-unused")),
                                    environment: { [:] }, mainWork: services.mainWork)
        services.machines.add(ssh)
        var chat = TabSnapshot(surface: SurfaceID(rawValue: 1), kind: .conversation, cwd: nil)
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:remote-thinking", hostName: "lab", session: Self.session, harness: "claude"))
        chat.notification = TabNotification(notification: NotificationID(rawValue: 9), unread: true, level: .info, source: "agent")
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat])])
        ssh.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "lab", screens: [screen])]))
        let workspace = try #require(ssh.daemon.store.workspaces.first)
        let design = DesignSettings.shared
        let before = design.attention
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/remote-thinking.sock", lanes: AgentLaneStore())
        defer {
            design.attention = before
            AgentTurnStateStore.shared.apply(session: Self.session, state: nil, lastMessage: nil, muted: false, title: nil, detail: nil, recordsTimeline: false)
        }
        design.attention = AttentionSettings()
        let notifications = services.notifications
        #expect(notifications.attentionMarks(for: workspace).count == 1, "the fixture's remote chat has no ring to stop")
        feed.handle(try Self.peerChange("lab", indicator: "working"))
        #expect(notifications.attentionMarks(for: workspace).isEmpty, "a remote chat that is thinking drew a ring")
        feed.handle(try Self.peerChange("lab", indicator: "working", stale: true))
        #expect(notifications.attentionMarks(for: workspace).count == 1, "a dropped peer's last state hid the ring")
        feed.handle(try Self.peerChange("elsewhere", indicator: "working"))
        #expect(notifications.attentionMarks(for: workspace).count == 1, "another machine's row stopped this chat's ring")
        feed.handle(try Self.peerChange("lab", indicator: "input"))
        #expect(notifications.attentionMarks(for: workspace).count == 1, "a remote chat waiting on the person lost its ring")
        feed.handle(try Self.peerChange("lab", indicator: "working"))
        feed.handle(try Self.peerChange("lab", indicator: "idle"))
        #expect(notifications.attentionMarks(for: workspace).count == 1, "the ring did not come back when the remote turn stopped")
    }

    /// The watch's first page carries the peers' rows too: a remote chat thinking when the app
    /// connects reads as working, and only through its own machine's peer.
    @Test func aWatchPagesPeerRowsReadAsTheirChatsState() throws {
        let line = #"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"\#(Self.session)","indicator":"working","peer":"lab"},{"sessionId":"stale-s2","indicator":"working","peer":"lab","stale":true}]}}"#
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/remote-thinking-page.sock", turns: turns, lanes: AgentLaneStore())
        feed.handle(try #require(AgentTurnStateFeed.Message(line: Data(line.utf8))))
        let ref = AgentSessionRef(host: "registry:remote-thinking", hostName: "lab", session: Self.session)
        #expect(turns.isWorking(ref, isChatMachine: { $0 == "lab" }), "a page's working peer row did not read as working")
        #expect(!turns.isWorking(ref, isChatMachine: { _ in false }), "a row of a peer that is not the chat's machine read as working")
        #expect(!turns.isWorking(AgentSessionRef(host: "registry:remote-thinking", session: "stale-s2"), isChatMachine: { _ in true }),
                "a stale peer row read as working")
        #expect(turns.state(for: ref) == nil, "the peer row leaked into the local state read")
    }
}
