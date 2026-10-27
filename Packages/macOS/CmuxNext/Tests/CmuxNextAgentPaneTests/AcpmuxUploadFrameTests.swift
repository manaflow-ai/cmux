import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxUploadFrameTests {
    @Test func binaryFramePreservesHeaderAndRawBytes() throws {
        let bytes = Data([0, 1, 2, 255])
        let frame = try AcpmuxUploadFrame(
            id: 41, sessionId: "s", uploadId: "u", offset: 9, bytes: bytes
        ).encoded()
        #expect(frame.prefix(4) == Data("AMUP".utf8))
        let decoded = try #require(AcpmuxUploadFrame.decode(frame))
        #expect(decoded.id == 41)
        #expect(decoded.sessionId == "s")
        #expect(decoded.uploadId == "u")
        #expect(decoded.offset == 9)
        #expect(decoded.bytes == bytes)
    }

    @Test func binaryFrameRejectsHeaderAndPayloadMismatch() throws {
        var frame = try AcpmuxUploadFrame(id: 1, sessionId: "s", uploadId: "u", offset: 0, bytes: Data([1])).encoded()
        frame[7] = 0
        #expect(AcpmuxUploadFrame.decode(frame) == nil)
    }

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
