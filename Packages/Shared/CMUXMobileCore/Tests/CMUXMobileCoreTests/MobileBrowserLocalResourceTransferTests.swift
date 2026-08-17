import CMUXMobileCore
import Foundation
import Testing

@Suite struct MobileBrowserLocalResourceTransferTests {
    @Test func chunkUsesBoundedSnakeCaseWireShape() throws {
        let chunk = MobileBrowserLocalResourceChunk(
            path: "/index.html",
            offset: 1024,
            totalSize: 4096,
            data: Data("hello".utf8),
            mimeType: "text/html",
            eof: false
        )

        let encoded = try JSONEncoder().encode(chunk)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["path"] as? String == "/index.html")
        #expect(object["offset"] as? Int == 1024)
        #expect(object["total_size"] as? Int == 4096)
        #expect(object["data_b64"] as? String == Data("hello".utf8).base64EncodedString())
        #expect(object["mime_type"] as? String == "text/html")
        #expect(object["eof"] as? Bool == false)
        #expect(object["totalSize"] == nil)
    }

    @Test func chunkRoundTripsDataAndMetadata() throws {
        let original = MobileBrowserLocalResourceChunk(
            path: "/assets/app.js",
            offset: 0,
            totalSize: 3,
            data: Data([1, 2, 3]),
            mimeType: "text/javascript",
            eof: true
        )
        let decoded = try JSONDecoder().decode(
            MobileBrowserLocalResourceChunk.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test func defaultPolicyKeepsResourceAndPageBudgetsBounded() {
        let policy = MobileBrowserLocalResourcePolicy()
        #expect(policy.maximumResourceBytes == 64 * 1024 * 1024)
        #expect(policy.maximumPageBytes == 128 * 1024 * 1024)
        #expect(policy.maximumChunkBytes == 1 * 1024 * 1024)
        #expect(policy.maximumPageBytes >= policy.maximumResourceBytes)
    }
}
