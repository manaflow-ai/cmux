import Foundation
import Testing
@testable import CmuxNextPages
import CmuxNextPagesTestSupport

@MainActor
struct ChromiumUploadBlobReaderTests {
    @Test func eachNextReadsOneChunkWithBlobHandleAndReleasesObject() async throws {
        let page = FakeChromiumPage()
        var reads = 0
        page.answer = { method, _ in
            switch method {
            case "Runtime.evaluate": return #"{"result":{"type":"object","className":"Blob","objectId":"object"}}"#
            case "IO.resolveBlob": return #"{"uuid":"blob-id"}"#
            case "IO.read":
                reads += 1
                return reads == 1
                    ? #"{"data":"YWJj","base64Encoded":false,"eof":false}"#
                    : #"{"data":"AP8=","base64Encoded":true,"eof":true}"#
            default: return "{}"
            }
        }
        let reader = ChromiumUploadBlobReader(page: page, context: 9, token: "token")
        #expect(reads == 0)
        #expect(try await reader.next() == Data("YWJj".utf8))
        #expect(reads == 1)
        #expect(try await reader.next() == Data([0, 255]))
        #expect(reads == 2)
        #expect(try await reader.next() == nil)
        await reader.close()
        #expect(page.calls.filter { $0.method == "IO.read" }.allSatisfy { $0.params["handle"] as? String == "blob:blob-id" })
        #expect(page.calls.contains { $0.method == "IO.close" && $0.params["handle"] as? String == "blob:blob-id" })
        #expect(page.calls.contains { $0.method == "Runtime.releaseObject" && $0.params["objectId"] as? String == "object" })
        #expect(page.calls.first?.params["contextId"] as? Int == 9)
    }

    @Test func missingBlobIsRefusedWithoutReadingBytes() async {
        let page = FakeChromiumPage()
        let reader = ChromiumUploadBlobReader(page: page, context: 11, token: "missing")
        await #expect(throws: AgentPageUploadError.invalidBlob) { try await reader.next() }
        #expect(!page.calls.contains { $0.method == "IO.read" })
    }
}
