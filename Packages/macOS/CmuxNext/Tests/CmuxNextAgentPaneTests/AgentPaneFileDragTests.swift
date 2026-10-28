#if DEBUG
import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextCompat
import Foundation
import Testing
import UniformTypeIdentifiers

/// A drag of a file out of an agent chat starts at once with no read, and reads an image's bytes and
/// picture off the main thread after the start (plans/cmux-next/threading-model.md). Each test binds its own blocking table, so a read on the main thread shows
/// as a site.
@MainActor @Suite(.serialized)
struct AgentPaneFileDragTests {
    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("file-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A 320 x 160 pixel PNG (72 dpi: 320 x 160 pt).
    private static func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 160, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func anImageIsReadOffTheMainThreadWithItsBytesAndPicture() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chart.png")
        let png = try Self.png()
        try png.write(to: file)

        let table = BlockingViolationTable(mode: .record)
        let contents = await BlockingViolationTable.$scoped.withValue(table) {
            await AgentPaneFileDrag.contents(of: file)
        }
        await table.flush()

        #expect(table.sites.isEmpty, "a drag read the file on the main thread: \(table.sites)")
        #expect(contents.data == png)
        let picture = try #require(contents.picture)
        #expect(picture.size == CGSize(width: 160, height: 80))
    }

    /// The drag starts in the event's turn (lead review, 2026-10-25): its pasteboard holds the file URL and
    /// name at once and answers the image types from the off-main read's bytes; it never reads the file.
    @Test func theDragPasteboardAnswersFromTheOffMainBytesAndNeverReads() throws {
        let file = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).png")
        let pasteboard = AgentPaneFileDragPasteboard(file: file)
        let item = pasteboard.item()
        #expect(item.string(forType: .fileURL) == file.absoluteString)
        #expect(pasteboard.imageTypes == [NSPasteboard.PasteboardType(UTType.png.identifier), .tiff])
        // Asked before the read ended: no data, and no read on the main thread (the file does not even exist).
        #expect(pasteboard.data(for: NSPasteboard.PasteboardType(UTType.png.identifier)) == nil)
        let png = try Self.png()
        pasteboard.bytes = png
        #expect(pasteboard.data(for: NSPasteboard.PasteboardType(UTType.png.identifier)) == png)
        #expect(pasteboard.data(for: .tiff) != nil)
    }

    @Test func anotherFileDeclaresNoImageType() {
        let pasteboard = AgentPaneFileDragPasteboard(file: URL(fileURLWithPath: "/tmp/notes.txt"))
        #expect(pasteboard.imageTypes.isEmpty)
        #expect(pasteboard.item().types.contains(.fileURL))
    }

    @Test func anotherFileCarriesNoBytesOrPicture() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)

        let contents = await AgentPaneFileDrag.contents(of: file)

        #expect(contents.data == nil)
        #expect(contents.picture == nil)
    }
}
#endif
