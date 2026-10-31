import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `/btw` side sessions at the pane boundary. A side session (`_acpmux/btw`) goes out like a prompt:
/// only on a gesture, only about a chat in the pane's scope, and only with the params the page
/// sends; its reply makes the new session the pane's, so `chat.sideChat` opens it beside the chat.
/// Side sessions then open where ``RightColumnPlacement`` says: a split right of the chat, one split
/// below what is on the right, then tabs in the lower pane, focused, never a new split each time.
@Suite(.serialized)
@MainActor
struct AgentSideSessionPaneTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    static func btw(id: Int, session: String, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/btw","params":{"sessionId":"\#(session)","question":"why is the build slow?"\#(extra)}}"#
    }

    static func sideChat(_ id: String) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": "chat.sideChat", "params": ["sessionId": id]])
    }

    @Test func aSideSessionGoesOutLikeAPromptAndOpensBesideItsChat() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("_acpmux/btw", with: #"{"sessionId":"side-1","model":"haiku","readOnly":"mode"}"#)
        let model = AgentPaneModel(host: NoHost(), sessionId: "chat-1")
        var opened: [String] = []
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() },
                                            openSide: { chat, fork in opened.append("\(chat)>\(fork)") })
        let transport = model.transport
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("chat-1")
        let asked = { server.peers.first?.frames.filter { $0.contains("_acpmux/btw") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.btw(id: 1, session: "chat-1")]) == .gestureRequired)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.btw(id: 2, session: "other")]) != nil,
                "a chat outside the pane's scope")
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.btw(id: 3, session: "chat-1", extra: #","cwd":"/"}"#)]) != nil,
                "a param the pane never sends")
        #expect(asked().isEmpty, "a refused side session reached acpmux: \(asked())")
        #expect(await model.respond(to: Self.sideChat("side-1"))["ok"] as? Bool != true,
                "a side session the pane never started opened")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.btw(id: 4, session: "chat-1", extra: #","model":"haiku""#)]) == nil)
        _ = await inbox.frame(containing: #""id":4"#)
        let sent = try #require(asked().first)
        let params = try #require((try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])?["params"] as? [String: Any])
        #expect(params["sessionId"] as? String == "chat-1")
        #expect(params["question"] as? String == "why is the build slow?")
        #expect(asked().count == 1)

        // The reply named the side session: it is the pane's, and the page's chat.sideChat opens it.
        #expect(transport.sessions.contains("side-1"))
        #expect(await model.respond(to: Self.sideChat("side-1"))["ok"] as? Bool == true)
        #expect(opened == ["chat-1>side-1"])
    }

    /// A window's panes as the app keeps them (``RightColumnWindow``). A split's move lands later,
    /// as the daemon's does, so an open asked for meanwhile has to wait for it.
    @MainActor final class Layout {
        let window = RightColumnWindow()
        var focused: String?
        var moves: [@MainActor () -> Void] = []

        func hooks() -> AgentSidePanes.Hooks {
            AgentSidePanes.Hooks(pane: { [weak self] in self?.window.paneOf[$0] }, column: { [unowned self] _ in window.measured }) { [unowned self] decision, session, created, finished in
                let key = "tab-\(session)"
                if case .tab = decision {
                    window.place(decision, key: key)
                    created(key)
                    focused = key
                    finished()
                    return true
                }
                window.paneOf[key] = "moving"
                created(key)
                moves.append { [unowned self] in
                    window.place(decision, key: key)
                    focused = key
                    finished()
                }
                return true
            }
        }

        func landMoves() {
            while !moves.isEmpty { moves.removeFirst()() }
        }
    }

    /// A chat whose side tabs all closed keeps no tracker: the next chat's lookup drops it, so the
    /// app does not hold one per chat that ever had a side session.
    @Test func aChatWhoseSideTabsAllClosedKeepsNoTracker() {
        let layout = Layout()
        let chat = "prune-\(UUID().uuidString)"
        let first = AgentSidePanes.chat(chat)
        first.open("s1", chat: "chat", hooks: layout.hooks())
        layout.landMoves()
        _ = AgentSidePanes.chat("other-\(UUID().uuidString)")
        #expect(AgentSidePanes.chat(chat) === first, "a tracker with an open side tab was dropped")

        layout.window.close("tab-s1")
        _ = AgentSidePanes.chat("other-\(UUID().uuidString)")
        #expect(AgentSidePanes.chat(chat) !== first, "a chat with no open side tab kept its tracker")
    }

    /// Side sessions open where ``RightColumnPlacement`` puts anything opened on the right: a split
    /// right of the chat, one split below it, then tabs in the lower pane (leo-workspace
    /// design/pane-placement.md; Leo 2026-10-30: "if there's already a thing on the right, there
    /// should be logic for just putting it on the lower pane of the right").
    @Test func sideSessionsSplitRightThenOnceBelowThenAreTabsInTheLowerPane() {
        let layout = Layout()
        let panes = AgentSidePanes()

        // The first opens a split right of the chat; a second asked for while it moves waits for it.
        #expect(panes.open("s1", chat: "chat", hooks: layout.hooks()))
        #expect(panes.open("s2", chat: "chat", hooks: layout.hooks()))
        layout.landMoves()
        #expect(layout.window.events == ["split right", "split below right1"])
        #expect(layout.focused == "tab-s2")

        // A third is a tab in the lower pane, focused: never another split.
        panes.open("s3", chat: "chat", hooks: layout.hooks())
        layout.landMoves()
        #expect(layout.window.events.last == "tab in right2")
        #expect(layout.focused == "tab-s3")
        #expect(layout.window.live == ["right1", "right2"])

        // Closing the lower pane's tabs collapses it: the next splits below again.
        layout.window.close("tab-s2")
        layout.window.close("tab-s3")
        #expect(layout.window.live == ["right1"])
        panes.open("s4", chat: "chat", hooks: layout.hooks())
        layout.landMoves()
        #expect(layout.window.events.last == "split below right1")
    }

    @Test func withSomethingAlreadyOnTheRightASideSessionSplitsBelowIt() {
        let layout = Layout()
        let panes = AgentSidePanes()
        layout.window.occupy("terminal")
        #expect(panes.open("s1", chat: "chat", hooks: layout.hooks()))
        layout.landMoves()
        #expect(layout.window.events == ["split below right1"])
        #expect(layout.window.paneOf["terminal"] == "right1", "what was on the right stays")
    }
}
