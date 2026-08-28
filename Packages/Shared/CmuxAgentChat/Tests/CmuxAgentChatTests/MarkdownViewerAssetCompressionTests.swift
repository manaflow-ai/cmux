import Foundation
import Testing
import zlib

@testable import CmuxAgentChat

@Suite("Markdown viewer asset compression")
struct MarkdownViewerAssetCompressionTests {
    @Test("inflates zlib-deflated assets back to the original bytes")
    func roundTripsDeflatedAsset() throws {
        let original = Data(String(repeating: "window.__cmuxRenderMarkdown = function(md) {};\n", count: 500).utf8)
        let deflated = try deflate(original)
        #expect(deflated.count < original.count)

        let inflated = MarkdownViewerAssetCompression.inflate(deflated)
        #expect(inflated == original)
    }

    @Test("empty input inflates to empty output")
    func emptyInput() {
        #expect(MarkdownViewerAssetCompression.inflate(Data()) == Data())
    }

    @Test("garbage input fails instead of returning partial bytes")
    func garbageInput() {
        #expect(MarkdownViewerAssetCompression.inflate(Data([0xDE, 0xAD, 0xBE, 0xEF])) == nil)
    }

    private func deflate(_ data: Data) throws -> Data {
        var destinationLength = uLong(compressBound(uLong(data.count)))
        var destination = [UInt8](repeating: 0, count: Int(destinationLength))
        let status = data.withUnsafeBytes { source -> Int32 in
            guard let base = source.bindMemory(to: Bytef.self).baseAddress else { return Z_BUF_ERROR }
            return compress2(&destination, &destinationLength, base, uLong(data.count), 9)
        }
        try #require(status == Z_OK)
        return Data(destination.prefix(Int(destinationLength)))
    }
}
