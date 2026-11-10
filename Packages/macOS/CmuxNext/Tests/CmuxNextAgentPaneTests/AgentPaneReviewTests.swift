import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The Review queue's verdicts (`review.accept`, `review.send`, ``AgentPaneReview``): only from the
/// Review page, on the person's own key or click, to a chat on this Mac's acpmux, writing only the
/// `review.done` tag; a send tags only once acpmux took the prompt.
private nonisolated let reviewSocket = "/tmp/acpmux-main.sock"

@MainActor
struct AgentPaneReviewTests {
    private static let socket = reviewSocket

    private actor Host: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func answerEnvironment(socket: String) async -> AcpmuxEnvironment? {
            guard socket == reviewSocket else { return nil }
            return AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/true"), home: URL(fileURLWithPath: "/tmp/acpmux-home"),
                                     socketPath: reviewSocket, daemonArguments: [], childEnvironment: [:])
        }
    }

    /// What reached acpmux: prompts and tags, in order.
    private actor Acpmux {
        var calls: [String] = []
        var delivers = true
        /// The chats this acpmux holds itself; any other `local/<id>` it would forward to a peer named `local`.
        var own: Set<String> = ["local/a1"]
        func record(_ call: String) { calls.append(call) }
        func setOwn(_ value: Set<String>) { own = value }
        func setDelivers(_ value: Bool) { delivers = value }
    }

    private static func page(review: Bool = true) -> AgentPaneModel {
        var page = AgentPaneNewTab(kind: .agent)
        page.review = review ? true : nil
        let model = AgentPaneModel(host: Host(), newTab: page, transport: AgentPaneTransport(gestures: AgentPaneUserGestures()))
        model.transport.acpmuxSocket = socket
        return model
    }

    private static func run(_ review: AgentPaneReview, _ model: AgentPaneModel, _ acpmux: Acpmux) async -> [String: Any] {
        await review.respond(in: model, deliver: { _, session, text, promptID in
            await acpmux.record("send \(session) \(promptID) \(text)")
            return await acpmux.delivers
        }, tag: { socket, session, set in
            await acpmux.record("tag \(socket) \(session) \(set.map { "\($0.key)=\($0.value)" }.joined())")
        }, owns: { socket, session in
            socket == reviewSocket ? await acpmux.own.contains(session) : false
        })
    }

    private static func code(_ reply: [String: Any]) -> String? {
        reply["ok"] as? Bool == true ? nil : (reply["error"] as? [String: Any])?["code"] as? String
    }

    private static let accept = AgentPaneReview(method: "review.accept", params: ["sessionId": "a1", "tag": "accepted:0badf00d"])!
    private static let send = AgentPaneReview(method: "review.send", params: [
        "sessionId": "a1", "tag": "changes:0badf00d", "text": "Use the shared helper.", "promptId": "p1",
    ])!

    @Test func theRequestsDecodeOnlyWithTheirOwnKeysAndATagOfTheirVerdict() {
        #expect(AgentPageOps.all.contains("cmux.agent.review.accept"))
        #expect(AgentPageOps.all.contains("cmux.agent.review.send"))
        #expect(AgentPaneRequest(body: ["method": "review.accept", "params": ["sessionId": "a1", "tag": "accepted:0badf00d"]]) == .review(Self.accept))
        let bad: [(String, [String: Any])] = [
            ("review.accept", ["sessionId": "a1", "tag": "changes:0badf00d"]),
            ("review.accept", ["sessionId": "a1", "tag": "accepted:not-hex"]),
            ("review.accept", ["sessionId": "a1", "tag": "pinned:1"]),
            ("review.accept", ["sessionId": "a1", "tag": "accepted:0badf00d", "set": ["pinned": "1"]]),
            ("review.accept", ["sessionId": "", "tag": "accepted:0badf00d"]),
            ("review.send", ["sessionId": "a1", "tag": "changes:0badf00d", "text": "   ", "promptId": "p1"]),
            ("review.send", ["sessionId": "a1", "tag": "accepted:0badf00d", "text": "x", "promptId": "p1"]),
            ("review.send", ["sessionId": "a1", "tag": "changes:0badf00d", "text": "x"]),
        ]
        for (method, params) in bad {
            #expect(AgentPaneReview(method: method, params: params) == nil, "\(method) \(params)")
        }
    }

    @Test func acceptTagsTheChatOnThePersonsKeyPress() async {
        let model = Self.page(), acpmux = Acpmux()
        #expect(Self.code(await Self.run(Self.accept, model, acpmux)) == "refused")
        #expect(await acpmux.calls.isEmpty)
        model.transport.gestures.record()
        #expect(Self.code(await Self.run(Self.accept, model, acpmux)) == nil)
        #expect(await acpmux.calls == ["tag \(Self.socket) local/a1 review.done=accepted:0badf00d"])
        // One key press, one verdict.
        #expect(Self.code(await Self.run(Self.accept, model, acpmux)) == "refused")
        #expect(await acpmux.calls.count == 1)
    }

    @Test func aSendTagsOnlyOnceAcpmuxTookThePrompt() async {
        let model = Self.page(), acpmux = Acpmux()
        await acpmux.setDelivers(false)
        model.transport.gestures.record()
        #expect(Self.code(await Self.run(Self.send, model, acpmux)) == "refused")
        #expect(await acpmux.calls == ["send local/a1 p1 Use the shared helper."])
        await acpmux.setDelivers(true)
        model.transport.gestures.record()
        #expect(Self.code(await Self.run(Self.send, model, acpmux)) == nil)
        #expect(await acpmux.calls.suffix(2) == ["send local/a1 p1 Use the shared helper.", "tag \(Self.socket) local/a1 review.done=changes:0badf00d"])
    }

    @Test func onlyTheReviewPageOnThisMacsAcpmuxForALocalChat() async {
        let acpmux = Acpmux()
        let chatPage = Self.page(review: false)
        chatPage.transport.gestures.record()
        #expect(Self.code(await Self.run(Self.accept, chatPage, acpmux)) == "unsupported")
        let other = AgentPaneReview(method: "review.accept", params: ["sessionId": "vm/a1", "tag": "accepted:0badf00d"])!
        let page = Self.page()
        page.transport.gestures.record()
        #expect(Self.code(await Self.run(other, page, acpmux)) == "unsupported")
        let elsewhere = Self.page()
        elsewhere.transport.acpmuxSocket = nil
        elsewhere.transport.gestures.record()
        #expect(Self.code(await Self.run(Self.accept, elsewhere, acpmux)) == "unsupported")
        #expect(await acpmux.calls.isEmpty)
    }

    /// A peer may be named `local`, and acpmux forwards a `local/<id>` that is not its own to it:
    /// a verdict on such an id writes nothing and spends no key press.
    @Test func aChatAcpmuxWouldForwardToAPeerNamedLocalIsNeverTagged() async {
        let model = Self.page(), acpmux = Acpmux()
        await acpmux.setOwn([])
        model.transport.gestures.record()
        #expect(Self.code(await Self.run(Self.accept, model, acpmux)) == "unsupported")
        #expect(Self.code(await Self.run(Self.send, model, acpmux)) == "unsupported")
        #expect(await acpmux.calls.isEmpty)
        await acpmux.setOwn(["local/a1"])
        #expect(Self.code(await Self.run(Self.accept, model, acpmux)) == nil, "the key press was not spent")
    }
}
