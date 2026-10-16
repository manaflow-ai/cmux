import CmuxCloudImagePaste
import Foundation
import Testing

@Suite("Cloud image paste package")
struct CloudImagePasteTests {
    @Test
    func validatesSupportedSignatures() throws {
        let png = try CloudClipboardImage(data: Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]))
        #expect(png.mime == "image/png")
    }

    @Test
    func rejectsUnsupportedAndOversizePayloads() {
        #expect(throws: CloudImagePasteError.unsupportedType) {
            try CloudClipboardImage(data: Data("<svg/>".utf8))
        }
        #expect(throws: CloudImagePasteError.sizeLimit) {
            try CloudClipboardImage(data: Data(repeating: 0, count: CloudClipboardImage.maximumBytes + 1))
        }
    }
}
