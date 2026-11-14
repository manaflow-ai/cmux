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

    /// Session ids are each daemon's own: two peers' rows can share one. A chat reads only its own
    /// machine's row, from the watch page and from each push, and a purge drops only that peer's.
    @Test func twoPeersRowsOfOneSessionIdKeepTheirOwnStates() throws {
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/remote-thinking-shared.sock", turns: turns, lanes: AgentLaneStore())
        let page = #"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"shared","indicator":"working","peer":"elsewhere"},{"sessionId":"shared","indicator":"done","peer":"lab"}]}}"#
        feed.handle(try #require(AgentTurnStateFeed.Message(line: Data(page.utf8))))
        let ref = AgentSessionRef(host: "registry:remote-thinking", hostName: "lab", session: "shared")
        #expect(!turns.isWorking(ref, isChatMachine: { $0 == "lab" }), "another peer's working row of the same id stopped lab's ring")
        #expect(turns.isWorking(ref, isChatMachine: { $0 == "elsewhere" }))
        func change(_ peer: String, _ indicator: String) throws -> AgentTurnStateFeed.Message {
            let line = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"shared","peer":"\#(peer)","session":{"sessionId":"shared","indicator":"\#(indicator)","peer":"\#(peer)"}}}"#
            return try #require(AgentTurnStateFeed.Message(line: Data(line.utf8)))
        }
        feed.handle(try change("lab", "working"))
        feed.handle(try change("elsewhere", "idle"))
        #expect(turns.isWorking(ref, isChatMachine: { $0 == "lab" }), "the later push of another peer's row overwrote lab's")
        #expect(!turns.isWorking(ref, isChatMachine: { $0 == "elsewhere" }))
        feed.handle(try change("elsewhere", "working"))
        let purge = #"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"shared","kind":"purged","peer":"elsewhere"}}"#
        feed.handle(try #require(AgentTurnStateFeed.Message(line: Data(purge.utf8))))
        #expect(!turns.isWorking(ref, isChatMachine: { $0 == "elsewhere" }), "a purged peer row still read as working")
        #expect(turns.isWorking(ref, isChatMachine: { $0 == "lab" }), "another peer's purge dropped lab's row")
    }

    /// A list too large for one message comes in pages (`nextCursor`): a chat on a later page has
    /// its state once the pages are read, and a push that came in between stays newer than them.
    @Test func aWatchResultInPagesReadsEveryPage() throws {
        let turns = AgentTurnStateStore()
        turns.localHost = "install:remote-thinking-pages"
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/remote-thinking-pages.sock", turns: turns, lanes: AgentLaneStore())
        func ref(_ session: String) -> AgentSessionRef { AgentSessionRef(host: "install:remote-thinking-pages", session: session) }
        func read(_ line: String) throws -> AgentTurnStateFeed.Message { try #require(AgentTurnStateFeed.Message(line: Data(line.utf8))) }
        feed.handle(try read(#"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"p1","indicator":"working"},{"sessionId":"p2","indicator":"working"}],"nextCursor":"k1"}}"#))
        feed.handle(try read(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"p2","session":{"sessionId":"p2","indicator":"done","unread":true}}}"#))
        feed.handle(try read(#"{"jsonrpc":"2.0","id":4,"result":{"sessions":[{"sessionId":"p3","indicator":"working"},{"sessionId":"r1","indicator":"working","peer":"lab"}],"nextCursor":null}}"#))
        #expect(turns.state(for: ref("p1")) == .working)
        #expect(turns.state(for: ref("p3")) == .working, "a chat on the watch's second page has no state")
        #expect(turns.state(for: ref("p2")) == .done, "the first page's older row overwrote a push that came after it")
        #expect(turns.isWorking(AgentSessionRef(host: "registry:remote-thinking", session: "r1"), isChatMachine: { $0 == "lab" }),
                "a peer row on the second page read as not working")
        #expect(turns.watching)
    }

    /// A peer's purge removes that peer's row: rows of purged sessions do not pile up over the
    /// app's life, and another peer's row of the same id stays.
    @Test func aPeersPurgeRemovesItsRow() throws {
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/remote-thinking-purge.sock", turns: turns, lanes: AgentLaneStore())
        func read(_ line: String) throws -> AgentTurnStateFeed.Message { try #require(AgentTurnStateFeed.Message(line: Data(line.utf8))) }
        feed.handle(try read(#"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"gone","indicator":"working","peer":"lab"},{"sessionId":"gone","indicator":"working","peer":"elsewhere"}]}}"#))
        #expect(Set(turns.peerRows("gone").keys) == ["lab", "elsewhere"])
        feed.handle(try read(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"gone","kind":"purged","peer":"lab"}}"#))
        #expect(Set(turns.peerRows("gone").keys) == ["elsewhere"], "a purged peer row stayed in the store")
    }

    /// A push for one peer's row while a paged watch result is read keeps only that row: the
    /// page's rows of other peers with the same session id still apply.
    @Test func aPeerPushWhilePagingKeepsOnlyItsOwnRow() throws {
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/remote-thinking-paging-peer.sock", turns: turns, lanes: AgentLaneStore())
        func read(_ line: String) throws -> AgentTurnStateFeed.Message { try #require(AgentTurnStateFeed.Message(line: Data(line.utf8))) }
        feed.handle(try read(#"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"shared","indicator":"working","peer":"lab"},{"sessionId":"shared","indicator":"working","peer":"elsewhere"}],"nextCursor":"k1"}}"#))
        feed.handle(try read(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"shared","peer":"elsewhere","session":{"sessionId":"shared","indicator":"idle","peer":"elsewhere"}}}"#))
        feed.handle(try read(#"{"jsonrpc":"2.0","id":4,"result":{"sessions":[],"nextCursor":null}}"#))
        let ref = AgentSessionRef(host: "registry:remote-thinking", session: "shared")
        #expect(turns.isWorking(ref, isChatMachine: { $0 == "lab" }), "a push for another peer dropped lab's row from the page")
        #expect(!turns.isWorking(ref, isChatMachine: { $0 == "elsewhere" }), "the page's older row overwrote the newer push")
    }

    /// A peer's purge while a paged watch result is read stays a purge: the page's older lane of
    /// that chat does not bring it back to the remote machines' sidebar.
    @Test func aPeerPurgeWhilePagingKeepsTheChatsLaneGone() throws {
        let lanes = AgentLaneStore()
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/remote-thinking-paging-purge.sock", turns: AgentTurnStateStore(), lanes: lanes)
        func read(_ line: String) throws -> AgentTurnStateFeed.Message { try #require(AgentTurnStateFeed.Message(line: Data(line.utf8))) }
        feed.handle(try read(#"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"gone","indicator":"working","peer":"lab","lane":{"state":"working"}}],"nextCursor":"k1"}}"#))
        feed.handle(try read(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"gone","kind":"purged","peer":"lab"}}"#))
        feed.handle(try read(#"{"jsonrpc":"2.0","id":4,"result":{"sessions":[],"nextCursor":null}}"#))
        #expect(lanes.lanes["gone"] == nil, "the page's older lane brought a purged peer chat back")
    }

    /// A peer's change whose summary does not repeat `peer` (the push names it beside the summary)
    /// is that peer's row, not a purge: the chat still reads as working.
    @Test func aPeerChangeWithoutPeerInItsSummaryKeepsTheRow() throws {
        let turns = AgentTurnStateStore()
        let feed = AgentTurnStateFeed(socketPath: "/nonexistent/remote-thinking-peer-change.sock", turns: turns, lanes: AgentLaneStore())
        func read(_ line: String) throws -> AgentTurnStateFeed.Message { try #require(AgentTurnStateFeed.Message(line: Data(line.utf8))) }
        feed.handle(try read(#"{"jsonrpc":"2.0","id":2,"result":{"sessions":[{"sessionId":"r1","indicator":"idle","peer":"lab"}]}}"#))
        feed.handle(try read(#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":{"sessionId":"r1","peer":"lab","kind":"status","session":{"sessionId":"r1","indicator":"working"}}}"#))
        let ref = AgentSessionRef(host: "registry:remote-thinking", session: "r1")
        #expect(turns.isWorking(ref, isChatMachine: { $0 == "lab" }), "a peer change without peer in its summary removed the row")
    }
}
