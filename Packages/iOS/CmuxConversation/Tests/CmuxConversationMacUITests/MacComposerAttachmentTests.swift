#if os(macOS)
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CmuxConversationMacUI

@MainActor @Suite struct MacComposerAttachmentTests {
    private func jpegFile() throws -> (URL, Data) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = try #require(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imph-\(UUID().uuidString).jpg")
        try data.write(to: url)
        return (url, data)
    }

    /// Finder copies an image file as its URL plus its name as a string;
    /// Messages attaches the photo instead of pasting the file name.
    @Test func finderCopyOfAnImageFilePastesThePhoto() throws {
        let (url, data) = try jpegFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("imph-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.lastPathComponent, forType: .string)

        #expect(MacComposerAttachment.pasteboardPrefersImages(pasteboard))
        let attachments = MacComposerAttachment.images(on: pasteboard)
        #expect(attachments.count == 1)
        // The original JPEG bytes go out, not a re-encoded PNG.
        #expect(attachments.first?.mimeType == "image/jpeg")
        #expect(attachments.first?.data == data)
    }

    @Test func plainTextStillPastesAsText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("imph-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        #expect(!MacComposerAttachment.pasteboardPrefersImages(pasteboard))
        #expect(MacComposerAttachment.images(on: pasteboard).isEmpty)
    }
}
#endif
