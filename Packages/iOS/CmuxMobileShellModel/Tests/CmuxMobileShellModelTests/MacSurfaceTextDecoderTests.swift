import Foundation
import Testing
@testable import CmuxMobileShellModel

struct MacSurfaceTextDecoderTests {
    @Test func decodesUTF8Text() {
        let data = Data("# Hello 世界 🎉".utf8)
        let decoded = MacSurfaceTextDecoder.decode(data)
        #expect(decoded.encoding == .utf8)
        #expect(decoded.text == "# Hello 世界 🎉")
    }

    @Test func fallsBackToISOLatin1ForInvalidUTF8() {
        // 0xE9 alone is invalid UTF-8 but is "é" in ISO-Latin-1.
        let data = Data([0x63, 0x61, 0x66, 0xE9])
        let decoded = MacSurfaceTextDecoder.decode(data)
        #expect(decoded.encoding == .isoLatin1)
        #expect(decoded.text == "café")
    }

    @Test func arbitraryBytesAlwaysDecode() {
        let data = Data([0xFF, 0xFE, 0x00, 0x80, 0x9F])
        let decoded = MacSurfaceTextDecoder.decode(data)
        #expect(decoded.encoding == .isoLatin1)
        #expect(decoded.text.count == 5)
    }

    @Test func emptyDataDecodesToEmptyUTF8() {
        let decoded = MacSurfaceTextDecoder.decode(Data())
        #expect(decoded.encoding == .utf8)
        #expect(decoded.text.isEmpty)
    }
}
