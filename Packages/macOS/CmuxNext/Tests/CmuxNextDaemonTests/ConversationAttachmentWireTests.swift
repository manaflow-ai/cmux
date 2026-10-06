import Foundation
import Testing
@testable import CmuxNextDaemon

/// Wire shapes of `local-attachments-v1` (cmux-tui spec/commands.md).
@Suite struct ConversationAttachmentWireTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func beginDeclaresTheFileAndItsPreviewInTheOwnersShape() throws {
        let attachment = ConversationAttachment(hash: "h", name: "shot.png", mimeType: "image/png", byteCount: 10, width: 4, height: 3,
                                                preview: ConversationDerivedImage(hash: "p", mimeType: "image/jpeg", byteCount: 2))
        let begin = try object(ConversationAttachmentUploadRequest.begin(conversation: "conv_A", attachment: attachment))
        #expect(begin["cmd"] == .string("conversation-attachment-upload"))
        #expect(begin["op"] == .string("begin"))
        #expect(begin["sha256"] == .string("h"))
        #expect(begin["byte_count"] == .number(10))
        #expect(begin["mime_type"] == .string("image/png"))
        #expect(begin["preview"] == .object(["sha256": .string("p"), "byte_count": .number(2), "mime_type": .string("image/jpeg")]))
        #expect(begin["poster"] == nil)
        #expect(begin["upload"] == nil)

        let chunk = try object(ConversationAttachmentUploadRequest.chunk(upload: "u1", piece: .preview, offset: 4, bytes: Data([1, 2, 3])))
        #expect(chunk["op"] == .string("chunk"))
        #expect(chunk["piece"] == .string("preview"))
        #expect(chunk["offset"] == .number(4))
        #expect(chunk["data"] == .string("AQID"))
        #expect(chunk["conversation"] == nil)
    }

    @Test func anAttachmentPartRoundTripsAndOthersStayUnknown() throws {
        let json = #"{"type":"attachment","hash":"h","name":"a.mov","mime_type":"video/quicktime","byte_count":9,"duration_ms":1500,"poster":{"hash":"p","mime_type":"image/jpeg","byte_count":3}}"#
        let part = try JSONDecoder().decode(ConversationPart.self, from: Data(json.utf8))
        let expected = ConversationAttachment(hash: "h", name: "a.mov", mimeType: "video/quicktime", byteCount: 9, durationMs: 1500,
                                              poster: ConversationDerivedImage(hash: "p", mimeType: "image/jpeg", byteCount: 3))
        #expect(part == .attachment(expected))
        #expect(part.plainText == "a.mov")
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(part))
        let original = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(encoded == original)
    }
}
