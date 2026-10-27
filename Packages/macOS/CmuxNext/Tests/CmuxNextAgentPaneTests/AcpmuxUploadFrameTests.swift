import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxUploadFrameTests {
    @Test func uploadControlDoesNotAllowDataBytesInPageParams() {
        let body: [String: Any] = [
            "method": "_acpmux/file_put_begin",
            "params": ["sessionId": "s", "fileName": "x", "size": 42],
        ]
        #expect(AcpmuxPaneMethods.breaksParamsRule(body, modeFields: nil) == false)
        #expect(AcpmuxPaneMethods.breaksParamsRule([
            "method": "_acpmux/file_put_begin",
            "params": ["sessionId": "s", "fileName": "x", "size": 42, "data": "AA=="],
        ], modeFields: nil))
    }

    @Test func promptUploadRefsSurviveWhileOtherBlockMetadataIsStripped() throws {
        let object: [String: Any] = [
            "method": "session/prompt",
            "params": [
                "prompt": [[
                    "type": "image",
                    "name": "shot.png",
                    "_meta": [
                        "acpmux": [
                            "upload": ["uploadId": "u", "fileName": "shot.png"],
                            "ignored": "remove",
                        ],
                        "ignored": true,
                    ],
                ]],
            ],
        ]
        let result = try #require(AcpmuxPaneMethods.strippingPromptMeta(object))
        let blocks = try #require((result["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
        let block = try #require(blocks.first)
        let meta = try #require(block["_meta"] as? [String: Any])
        let acpmux = try #require(meta["acpmux"] as? [String: Any])
        let upload = try #require(acpmux["upload"] as? [String: Any])
        #expect(upload["uploadId"] as? String == "u")
        #expect(upload["fileName"] as? String == "shot.png")
        #expect(acpmux.count == 1)
        #expect(meta.count == 1)
    }

    @Test func resourceUploadRefKeepsOnlyExactUri() throws {
        let object: [String: Any] = [
            "method": "session/prompt",
            "params": [
                "prompt": [[
                    "type": "resource_link",
                    "uri": "acpmux-upload:u",
                    "name": "data.bin",
                    "_meta": ["acpmux": ["upload": ["uploadId": "u", "fileName": "data.bin"]]],
                ]],
            ],
        ]
        let result = try #require(AcpmuxPaneMethods.strippingPromptMeta(object))
        let blocks = try #require((result["params"] as? [String: Any])?["prompt"] as? [[String: Any]])
        let block = try #require(blocks.first)
        #expect((block["uri"] as? String) == "acpmux-upload:u")
        let upload = try #require(((block["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["upload"] as? [String: Any])
        #expect(upload["uploadId"] as? String == "u")
    }
    @Test func invalidOrNestedUploadMetadataDoesNotSurvive() throws {
        for block: [String: Any] in [
            ["type": "image", "data": "AA==", "_meta": ["acpmux": ["upload": ["uploadId": "u", "fileName": "x"]]]],
            ["type": "resource_link", "uri": "acpmux-upload:other", "_meta": ["acpmux": ["upload": ["uploadId": "u", "fileName": "x"]]]],
            ["type": "text", "annotations": ["type": "image", "_meta": ["acpmux": ["upload": ["uploadId": "u", "fileName": "x"]]]]],
        ] {
            let frame: [String: Any] = ["method": "session/prompt", "params": ["prompt": [block]]]
            let result = try #require(AcpmuxPaneMethods.strippingPromptMeta(frame))
            let data = try JSONSerialization.data(withJSONObject: result)
            #expect(!String(decoding: data, as: UTF8.self).contains("uploadId"))
        }
    }

    @Test @MainActor func socketCloseAnswersPendingHostUpload() async throws {
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            wire: ClosingUploadWire(), limits: transport.limits,
            options: transport.permissionOptions, sessions: transport.sessions,
            ids: AcpmuxRequestIds(), signal: {})
        try await socket.start(timeout: 1)
        await #expect(throws: AgentPaneUploadError.rpc("upload connection closed")) {
            try await socket.callHost("_acpmux/file_put_begin", params: ["sessionId": "s", "fileName": "x", "size": 1])
        }
    }

    @Test @MainActor func uploadsRequireNativeOriginAndPaneSessionScope() async throws {
        let wire = UploadWire()
        let transport = AgentPaneTransport()
        let socket = AcpmuxPaneSocket(
            request: URLRequest(url: URL(string: "ws://127.0.0.1")!),
            wire: wire, limits: transport.limits, options: transport.permissionOptions,
            sessions: transport.sessions, ids: AcpmuxRequestIds(), signal: {})
        try await socket.start(timeout: 1)
        transport.socket = socket
        transport.current = 1
        transport.uploadOriginAllowed = true
        await #expect(throws: AgentPaneUploadError.rpc("upload session outside pane scope")) {
            try await transport.uploadControl(connection: 1, method: "_acpmux/file_put_begin", params: ["sessionId": "foreign"])
        }
        await #expect(throws: AgentPaneUploadError.rpc("upload session outside pane scope")) {
            try await transport.uploadChunk(connection: 1, sessionId: "foreign", uploadId: "u", offset: 0, bytes: Data([1]))
        }
        #expect(wire.sentCount.withLock { $0 } == 0)
        transport.sessions.add("owned")
        transport.uploadOriginAllowed = false
        await #expect(throws: AgentPaneUploadError.rpc("uploads require a native app connection")) {
            try await transport.uploadControl(connection: 1, method: "_acpmux/file_put_cancel", params: ["sessionId": "owned"])
        }
        #expect(wire.sentCount.withLock { $0 } == 0)
        socket.close(code: 1000, reason: "", error: nil)
    }

    final class UploadWire: AcpmuxPaneWire, Sendable {
        let sentCount = Mutex(0)
        private let incoming = Mutex<(@Sendable (String) -> Void)?>(nil)
        func open(onFrame: @escaping @Sendable (String) -> Void,
                  onClose: @escaping @Sendable (Int, String) -> Void) async throws {
            incoming.withLock { $0 = onFrame }
        }
        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
            sentCount.withLock { $0 += 1 }
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            let id = object?["id"] as? Int ?? 0
            let result = #"{"offset":2}"#
            incoming.withLock { $0 }?(#"{"id":\#(id),"result":\#(result)}"#)
            completion(true)
        }
        func cancel(code: Int, reason: String) {}
    }

    final class ClosingUploadWire: AcpmuxPaneWire, Sendable {
        private let closed = Mutex<(@Sendable (Int, String) -> Void)?>(nil)
        func open(onFrame: @escaping @Sendable (String) -> Void,
                  onClose: @escaping @Sendable (Int, String) -> Void) async throws {
            closed.withLock { $0 = onClose }
        }
        func send(_ text: String, completion: @escaping @Sendable (Bool) -> Void) {
            completion(true)
            closed.withLock { $0 }?(1006, "")
        }
        func cancel(code: Int, reason: String) {}
    }
}
