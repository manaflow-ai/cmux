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
    let server = AcpmuxStandInServer()
    try await server.start()
    defer { server.stop() }
    let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
    let connection = try await model.transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil, socketPath: socket))
    defer { model.transport.close(connection: connection) }
    let request = AgentPaneRequest(body: [
        "method": "chat.btw.inline",
        "params": ["question": "What changed?", "sessionId": "session-1"],
    ])

    let ungestured = await model.respond(to: request)
    #expect((ungestured["error"] as? [String: Any])?["code"] as? String == "transport.gesture_required")

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
    #expect((replayed["error"] as? [String: Any])?["code"] as? String == "transport.gesture_required")
}

@Test("native inline btw preserves folder trust refusals", arguments: ["trust.pending", "trust.untrusted"])
@MainActor
func inlineBtwPreservesTrustRefusal(reason: String) async throws {
    let socket = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).sock").path
    let refusal: [String: Any] = [
        "jsonrpc": "2.0", "id": 2,
        "error": ["code": -32000, "message": "Answer the folder trust question first",
                  "data": ["reason": reason, "cwd": "/tmp/btw-untrusted"]],
    ]
    let encoded = try JSONSerialization.data(withJSONObject: refusal)
    let relay = try OneShotRelay(path: socket, replies: [
        #"{"jsonrpc":"2.0","id":1,"result":{"_meta":{"acpmux":{"origin":"local"}}}}"#,
        String(decoding: encoded, as: UTF8.self),
    ])
    defer { relay.stop() }
    let server = AcpmuxStandInServer()
    try await server.start()
    defer { server.stop() }
    let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
    let connection = try await model.transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil, socketPath: socket))
    defer { model.transport.close(connection: connection) }
    model.transport.gestures.record(click: true)
    let reply = await model.respond(to: .btwInline(question: "What changed?", sessionId: "session-1"))
    let error = try #require(reply["error"] as? [String: Any])
    #expect(error["code"] as? String == reason)
    #expect(error["origin"] as? String == "session_host")
    #expect(error["retryable"] as? Bool == true)
    let details = try #require(error["details"] as? [String: Any])
    #expect(details["reason"] as? String == reason)
    #expect(details["cwd"] as? String == "/tmp/btw-untrusted")
    #expect(!model.transport.gestures.isAvailable)
    #expect(await relay.waitForRequest(containing: "_acpmux/btw"), "the request reached the daemon relay")
}

@Test("remote inline btw leaves its gesture for the legacy fallback")
@MainActor
func remoteInlineBtwDoesNotConsumeGesture() async {
    let model = AgentPaneModel(host: NoHost(), sessionId: "session-1")
    model.remoteChat = true
    model.transport.gestures.record(click: true)

    let reply = await model.respond(to: .btwInline(question: "What changed?", sessionId: "session-1"))

    #expect((reply["error"] as? [String: Any])?["code"] as? String == "unsupported")
    #expect(model.transport.gestures.isAvailable, "remote inline rejection leaves the fallback gesture")
}
