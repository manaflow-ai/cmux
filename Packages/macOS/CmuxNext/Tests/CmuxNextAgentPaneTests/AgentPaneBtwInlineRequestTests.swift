import Foundation
import Testing
@testable import CmuxNextAgentPane

private actor NoHost: AgentPaneHostProviding {
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
}

@Test("native inline btw request decodes to the acpmux handler case")
func inlineBtwRequestDecodes() {
    let request = AgentPaneRequest(body: [
        "method": "chat.btw.inline",
        "params": ["question": "What changed?", "sessionId": "session-1"],
    ])
    #expect(request == .btwInline(question: "What changed?", sessionId: "session-1"))
    #expect(request.description == "btwInline")
}

@Test("native inline btw consumes one gesture ticket")
@MainActor
func inlineBtwRequiresGesture() async throws {
    let socket = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).sock").path
    let relay = try OneShotRelay(path: socket, replies: [
        #"{"jsonrpc":"2.0","id":1,"result":{"_meta":{"acpmux":{"origin":"local"}}}}"#,
        #"{"jsonrpc":"2.0","id":2,"result":{"text":"answer from daemon"}}"#,
    ])
    defer { relay.stop() }
    let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
    model.transport.acpmuxSocket = socket
    let request = AgentPaneRequest(body: [
        "method": "chat.btw.inline",
        "params": ["question": "What changed?", "sessionId": "session-1"],
    ])

    let ungestured = await model.respond(to: request)
    #expect((ungestured["error"] as? [String: Any])?["code"] as? String == "acpmux.gesture_required")

    model.transport.gestures.record(click: true)
    let forwarded = await model.respond(to: request)
    #expect((forwarded["value"] as? [String: Any])?["text"] as? String == "answer from daemon")
    #expect(!model.transport.gestures.isAvailable, "the inline request spends its one-use gesture")

    let calls = relay.requests
    let btw = try #require(calls.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.first { $0["method"] as? String == "_acpmux/btw" })
    let params = try #require(btw["params"] as? [String: Any])
    #expect(params["sessionId"] as? String == "session-1")
    #expect(params["question"] as? String == "What changed?")
    #expect(params["inline"] as? Bool == true)

    let replayed = await model.respond(to: request)
    #expect((replayed["error"] as? [String: Any])?["code"] as? String == "acpmux.gesture_required")
}
