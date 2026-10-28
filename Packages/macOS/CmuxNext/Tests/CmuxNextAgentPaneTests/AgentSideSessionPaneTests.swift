import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// `/btw` side sessions at the pane boundary. A side session (`_acpmux/btw`) goes out like a prompt:
/// only on a gesture, only about a chat in the pane's scope, and only with the params the page
/// sends; its reply makes the new session the pane's, so `chat.sideChat` opens it beside the chat.
/// Side sessions then share one right pane (Leo 2026-10-14): the first opens a split right of the
/// chat, each later one a tab in that pane, focused, never a new split each time.
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
        let model = AgentPaneModel(runner: BackgroundWork(label: "test.agent-pane"), host: NoHost(), sessionId: "chat-1")
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

    /// A window's panes as the app keeps them: tab key to pane. A split's move lands later, as the
    /// daemon's does, so an open asked for meanwhile has to wait for it.
    @MainActor final class Layout {
        var panes: [String: String] = ["chat": "left"]
        var focused: String?
        var events: [String] = []
        var moves: [@MainActor () -> Void] = []
        private var count = 0

        private func newTab(_ session: String) -> String {
            count += 1
            return "tab-\(session)"
        }

        func hooks() -> AgentSidePanes.Hooks {
            AgentSidePanes.Hooks(pane: { [weak self] in self?.panes[$0] }, addTab: { [unowned self] anchor, session, created, finished in
                guard let pane = panes[anchor] else { return false }
                let key = newTab(session)
                panes[key] = pane
                created(key)
                focused = key
                events.append("tab \(session) in \(pane)")
                finished()
                return true
            }, split: { [unowned self] session, created, finished in
                let key = newTab(session)
                panes[key] = panes["chat"]
                created(key)
                moves.append { [unowned self] in
                    let pane = "right-\(count)"
                    panes[key] = pane
                    focused = key
                    events.append("split \(session) to \(pane)")
                    finished()
                }
                return true
            })
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

        layout.panes["tab-s1"] = nil
        _ = AgentSidePanes.chat("other-\(UUID().uuidString)")
        #expect(AgentSidePanes.chat(chat) !== first, "a chat with no open side tab kept its tracker")
    }

    @Test func laterSideSessionsOfAChatOpenAsTabsInItsOneRightPane() {
        let layout = Layout()
        let panes = AgentSidePanes()

        // The first opens a split right of the chat; a second asked for while it moves waits for it.
        #expect(panes.open("s1", chat: "chat", hooks: layout.hooks()))
        #expect(panes.open("s2", chat: "chat", hooks: layout.hooks()))
        layout.landMoves()
        #expect(layout.events == ["split s1 to right-1", "tab s2 in right-1"])
        #expect(layout.focused == "tab-s2")

        // A third lands there too, focused.
        panes.open("s3", chat: "chat", hooks: layout.hooks())
        layout.landMoves()
        #expect(layout.events.last == "tab s3 in right-1")
        #expect(layout.focused == "tab-s3")
        #expect(Set(["tab-s1", "tab-s2", "tab-s3"].compactMap { layout.panes[$0] }) == ["right-1"],
                "side sessions spread over more than one pane: \(layout.panes)")

        // Side tabs moved back into the chat's pane, or closed, leave no side pane: the next splits.
        layout.panes["tab-s3"] = "left"
        layout.panes["tab-s1"] = nil
        layout.panes["tab-s2"] = nil
        panes.open("s4", chat: "chat", hooks: layout.hooks())
        layout.landMoves()
        #expect(layout.events.last == "split s4 to right-4")
    }
}
