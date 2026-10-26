import Foundation
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
}
