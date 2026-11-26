import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// The chat's normal source path keeps the optimistic copy from the composer and
/// links it into the prompt. This exercises the wire, rather than only the
/// prestager and prompt-block helpers independently.
@MainActor
@Suite struct AttachmentPromptUploadIntegrationTests {
    struct Call: Sendable {
        let method: String
        let request: Data
    }

    final class Mac: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _uploadedBytes = Data()

        var calls: [Call] { lock.withLock { _calls } }
        var uploadedBytes: Data { lock.withLock { _uploadedBytes } }
        func record(_ method: String, _ request: Data) {
            lock.withLock { _calls.append(Call(method: method, request: request)) }
        }
        func appendUploadedBytes(_ data: Data, at offset: Int) {
            lock.withLock {
                guard offset == _uploadedBytes.count else { return }
                _uploadedBytes.append(data)
            }
        }

        func link() -> MockMacLink {
            MockMacLink { [self] _, data in
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let method = object["method"] as? String else { return [] }
                record(method, data)
                let id = object["id"].map { "\($0)" } ?? "null"
                func reply(_ result: String) -> Data {
                    Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
                }
                switch method {
                case "initialize":
                    return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"fullAccess":true,"features":["promptUploads","filePutChunks"]}}}"#)]
                case "_acpmux/watch":
                    return [reply(#"{"sessions":[{"sessionId":"s1","name":"lane","harness":"claude","cwd":"/tmp/w","status":"running"}]}"#)]
                case "_acpmux/attach":
                    return [reply(#"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":false,"lastSeq":0,"events":[]}"#)]
                case "_acpmux/file_put_begin":
                    return [reply(#"{"uploadId":"upload-1","ownerToken":"owner-1","fileName":"photo.png"}"#)]
                case "_acpmux/file_put_chunk":
                    let params = object["params"] as? [String: Any]
                    let offset = (params?["offset"] as? NSNumber)?.intValue ?? 0
                    let data = Data(base64Encoded: params?["data"] as? String ?? "") ?? Data()
                    appendUploadedBytes(data, at: offset)
                    return [reply(#"{"offset":\#(offset + data.count)}"#)]
                case "_acpmux/file_put_finish":
                    let params = object["params"] as? [String: Any]
                    let uploadID = params?["uploadId"] as? String ?? "upload-1"
                    let size = uploadedBytes.count
                    return [reply(#"{"path":"/w/.cmux/attachments/photo.png","size":\#(size),"uploadId":"\#(uploadID)"}"#)]
                case "session/prompt":
                    return [reply(#"{"stopReason":"end_turn"}"#)]
                default:
                    return [reply("{}")]
                }
            }
        }
    }

    static let summary = AgentSessionSummary(id: "s1", name: "lane", harness: "claude", agentName: "Claude",
                                             cwd: "/tmp/w", workspaceTitle: "w", macName: "mini")

    static func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func composerPrestageIsUsedByTheNormalChatSend() async throws {
        let mac = Mac()
        let hub = AcpmuxHub()
        await hub.bind(try await mac.link().openChannel(service: "acpmux", args: [:]))
        let source = hub.source(sessionID: "s1", summary: Self.summary)
        let store = AgentChatStore(source: source)
        let fixture = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let image = AgentAttachment(id: "photo", kind: .image, name: "photo.png", data: fixture)

        // This is the same callback ChatComposer uses as the attachment is picked.
        store.composerAttachmentsChanged([image])
        await Self.waitUntil { mac.calls.contains { $0.method == "_acpmux/file_put_begin" } }
        await Self.waitUntil { mac.calls.contains { $0.method == "_acpmux/file_put_finish" } }
        let earlyBegin = try #require(mac.calls.first { $0.method == "_acpmux/file_put_begin" })
        let earlyFinish = try #require(mac.calls.first { $0.method == "_acpmux/file_put_finish" })
        _ = (earlyBegin, earlyFinish)

        // Send through AgentChatStore and AcpmuxSessionSource, retaining the early copy.
        store.send(prompt: "see", attachments: [image])
        await Self.waitUntil { mac.calls.contains { $0.method == "session/prompt" } }

        let calls = mac.calls
        let beginIndices = calls.indices.filter { calls[$0].method == "_acpmux/file_put_begin" }
        let finishIndices = calls.indices.filter { calls[$0].method == "_acpmux/file_put_finish" }
        let beginIndex = try #require(beginIndices.first)
        let finishIndex = try #require(finishIndices.first)
        let promptIndex = try #require(calls.firstIndex { $0.method == "session/prompt" })
        #expect(beginIndices.count == 1, "the attachment is uploaded once, at pick time")
        #expect(finishIndices.count == 1)
        #expect(beginIndex < promptIndex)
        #expect(finishIndex < promptIndex)
        #expect(mac.uploadedBytes == fixture)

        let prompt = try JSONDecoder().decode(JSONValue.self, from: calls[promptIndex].request)
        let blocks = try #require(prompt["params"]?["prompt"]?.arrayValue)
        let imageBlock = try #require(blocks.first { $0["type"]?.stringValue == "image" })
        let upload = imageBlock["_meta"]?["acpmux"]?["upload"]
        #expect(upload?["uploadId"]?.stringValue == "upload-1")
        #expect(upload?["fileName"]?.stringValue == "photo.png")
        #expect(upload?["owned"]?.stringValue == "owner-1")
    }
}
