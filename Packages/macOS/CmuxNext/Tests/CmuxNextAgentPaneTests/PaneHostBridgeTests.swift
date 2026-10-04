import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Chromium page as the CEF bridge sees it: records calls, answers the
/// sender probe with `sender`, and lets the test emit protocol events.
private final class FakeChannel: PaneDevToolsChannel {
    var calls: [(method: String, params: [String: any Sendable])] = []
    /// What `[location.href, window === window.top]` evaluates to, by context.
    var senders: [Int: (href: String, isTop: Bool)] = [:]
    private var continuation: AsyncStream<PaneDevToolsEvent>.Continuation?

    func devToolsCall(_ method: String, params: [String: any Sendable]) async throws -> String {
        calls.append((method, params))
        switch method {
        case "Page.addScriptToEvaluateOnNewDocument":
            return #"{"identifier":"7"}"#
        case "Runtime.evaluate" where (params["expression"] as? String)?.hasPrefix("[location.href") == true:
            guard let context = params["contextId"] as? Int, let sender = senders[context] else {
                return #"{"result":{"type":"undefined"},"exceptionDetails":{"text":"no context"}}"#
            }
            return #"{"result":{"type":"object","value":["\#(sender.href)",\#(sender.isTop)]}}"#
        default:
            return "{}"
        }
    }

    func devToolsEvents() -> AsyncStream<PaneDevToolsEvent> {
        let (stream, continuation) = AsyncStream<PaneDevToolsEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func emitBindingCall(name: String = CEFPaneHostBridge.bindingName, context: Int, seq: Int, body: [String: Any]) throws {
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["seq": seq, "body": body]), as: UTF8.self)
        let params = String(decoding: try JSONSerialization.data(withJSONObject: [
            "name": name, "payload": payload, "executionContextId": context,
        ]), as: UTF8.self)
        continuation?.yield(PaneDevToolsEvent(method: "Runtime.bindingCalled", params: params))
    }

    /// The reply expressions sent back, with the context each went to.
    var replies: [(context: Int, expression: String)] {
        calls.compactMap { call in
            guard call.method == "Runtime.evaluate", let expression = call.params["expression"] as? String,
                  expression.contains(CEFPaneHostBridge.resolveName), let context = call.params["contextId"] as? Int
            else { return nil }
            return (context, expression)
        }
    }
}

private let bundledPage = URL(fileURLWithPath: "/tmp/agent-pane/index.html")
private let source = AgentPaneSource.bundled(bundledPage)

/// The handler a pane installs: the shared trust rule, then a fixed answer.
private func trustingHandler(_ seen: Box) -> PaneHostHandler {
    { message in
        seen.messages.append(message)
        guard PaneHostTrust.isTrusted(message, source: source) else {
            return AgentPaneReply.failure(code: "untrusted_frame", message: "Untrusted frame")
        }
        return AgentPaneReply.handshake(.mock)
    }
}

private final class Box {
    var messages: [PaneHostMessage] = []
}

private func waitForReplies(_ channel: FakeChannel, count: Int) async {
    for _ in 0..<10_000 where channel.replies.count < count { await Task.yield() }
}

@Suite struct PaneHostBridgeTests {
    @Test func installAddsTheBindingAndTheWebKitShapedScriptBeforeTheFirstLoad() async throws {
        let channel = FakeChannel()
        let bridge = CEFPaneHostBridge(channel: channel)
        try await bridge.install(trustingHandler(Box()))
        #expect(channel.calls.map(\.method) == ["Runtime.addBinding", "Page.addScriptToEvaluateOnNewDocument"])
        #expect(channel.calls[0].params["name"] as? String == CEFPaneHostBridge.bindingName)
        let script = try #require(channel.calls[1].params["source"] as? String)
        #expect(script.contains("messageHandlers"))
        #expect(script.contains(#""agentSession""#))
    }

    @Test func theTrustedTopDocumentGetsTheHandshakeInItsOwnContext() async throws {
        let channel = FakeChannel()
        channel.senders[3] = (source.pageURL.absoluteString, true)
        let seen = Box()
        let bridge = CEFPaneHostBridge(channel: channel)
        try await bridge.install(trustingHandler(seen))
        try channel.emitBindingCall(context: 3, seq: 1, body: ["id": "a", "method": "ready", "params": [:]])
        await waitForReplies(channel, count: 1)
        let reply = try #require(channel.replies.first)
        #expect(reply.context == 3)
        #expect(reply.expression.hasPrefix("globalThis.\(CEFPaneHostBridge.resolveName)?.(1, "))
        #expect(reply.expression.contains(#""ok":true"#))
        #expect(reply.expression.contains(#""transport":"mock""#))
        let message = try #require(seen.messages.first)
        #expect(message.isMainFrame)
        #expect(AgentPaneRequest(body: message.body) == .ready)
    }

    /// A same-process iframe has the binding too; its own context says it
    /// is not the top document, so it is refused, even on the pane's URL.
    @Test func anIframeOrAnotherPageIsRefused() async throws {
        let channel = FakeChannel()
        channel.senders[4] = (source.pageURL.absoluteString, false)
        channel.senders[5] = ("https://example.com/", true)
        let bridge = CEFPaneHostBridge(channel: channel)
        try await bridge.install(trustingHandler(Box()))
        try channel.emitBindingCall(context: 4, seq: 1, body: ["method": "ready"])
        try channel.emitBindingCall(context: 5, seq: 2, body: ["method": "ready"])
        await waitForReplies(channel, count: 2)
        #expect(channel.replies.count == 2)
        #expect(channel.replies.allSatisfy { $0.expression.contains("untrusted_frame") })
    }

    /// A context that is gone (navigated away) cannot prove where it is.
    @Test func aSenderThatCannotBeProbedIsUntrusted() async throws {
        let channel = FakeChannel()
        let bridge = CEFPaneHostBridge(channel: channel)
        try await bridge.install(trustingHandler(Box()))
        try channel.emitBindingCall(context: 9, seq: 1, body: ["method": "ready"])
        await waitForReplies(channel, count: 1)
        #expect(channel.replies.first?.expression.contains("untrusted_frame") == true)
    }

    @Test func otherBindingsAndMalformedPayloadsAreIgnored() async throws {
        let channel = FakeChannel()
        channel.senders[3] = (source.pageURL.absoluteString, true)
        let seen = Box()
        let bridge = CEFPaneHostBridge(channel: channel)
        try await bridge.install(trustingHandler(seen))
        try channel.emitBindingCall(name: "somethingElse", context: 3, seq: 1, body: ["method": "ready"])
        try channel.emitBindingCall(context: 3, seq: 0, body: ["method": "ready"])
        try channel.emitBindingCall(context: 3, seq: 2, body: ["method": "ready"])
        await waitForReplies(channel, count: 1)
        #expect(seen.messages.count == 1)
        #expect(channel.replies.map(\.expression).allSatisfy { $0.contains("?.(2, ") })
    }

    @Test func uninstallStopsAnsweringAndRemovesTheBinding() async throws {
        let channel = FakeChannel()
        channel.senders[3] = (source.pageURL.absoluteString, true)
        let bridge = CEFPaneHostBridge(channel: channel)
        try await bridge.install(trustingHandler(Box()))
        bridge.uninstall()
        for _ in 0..<1_000 where !channel.calls.contains(where: { $0.method == "Page.removeScriptToEvaluateOnNewDocument" }) {
            await Task.yield()
        }
        #expect(channel.calls.contains { $0.method == "Runtime.removeBinding" })
        #expect(channel.calls.contains { $0.method == "Page.removeScriptToEvaluateOnNewDocument" && $0.params["identifier"] as? String == "7" })
        try channel.emitBindingCall(context: 3, seq: 1, body: ["method": "ready"])
        for _ in 0..<1_000 { await Task.yield() }
        #expect(channel.replies.isEmpty)
    }

    @Test func wireValuesRoundTrip() {
        #expect(CEFPaneHostWire.jsonString("a\"b") == #""a\"b""#)
        #expect(CEFPaneHostWire.Sender(evaluation: #"{"result":{"value":["cmux-agent://pane/index.html",true]}}"#)
            == CEFPaneHostWire.Sender(url: URL(string: "cmux-agent://pane/index.html"), isTop: true))
        #expect(CEFPaneHostWire.Sender(evaluation: #"{"result":{"value":"x"}}"#) == nil)
        #expect(CEFPaneHostWire.Request(payload: #"{"seq":1,"body":"no"}"#) == nil)
        let invalid = CEFPaneHostWire.resolveExpression(seq: 4, reply: ["date": Date()])
        #expect(invalid.contains("native.invalid_reply"))
    }

    @Test func theSharedTrustRuleMatchesTheWebKitBridge() {
        #expect(PaneHostTrust.isTrusted(PaneHostMessage(frameURL: source.pageURL, isMainFrame: true, body: [:]), source: source))
        #expect(!PaneHostTrust.isTrusted(PaneHostMessage(frameURL: source.pageURL, isMainFrame: false, body: [:]), source: source))
        #expect(!PaneHostTrust.isTrusted(
            PaneHostMessage(frameURL: URL(string: "cmux-agent://pane/other.html"), isMainFrame: true, body: [:]), source: source))
    }
}
