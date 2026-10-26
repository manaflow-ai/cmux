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

    /// A `width` x `height` pixel PNG (72 dpi: as many points), 320 x 160 by default.
    private static func png(width: Int = 320, height: Int = 160) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// `png`'s pasteboard image, made off the main thread as the drag's read makes it.
    @concurrent private nonisolated static func pasteboardImage(_ png: Data) async -> AgentPanePasteboardImage {
        AgentPanePasteboardImage(png, type: .png)
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

        // The read runs on the cooperative pool today (a pool site; p02-threads 047 moves it onto a lane).
        #expect(table.sites.filter { $0.context == .main }.isEmpty, "a drag read the file on the main thread: \(table.sites)")
        #expect(contents.image?.data == png)
        #expect(contents.image?.tiff.flatMap(NSBitmapImageRep.init(data:))?.pixelsWide == 320, "the TIFF is made by the read")
        let picture = try #require(contents.picture)
        #expect(picture.size == CGSize(width: 160, height: 80))
        // The picture is the read's decoded thumbnail (160 pt at 2x), so drawing the drag image decodes nothing.
        #expect(picture.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == AgentPaneFileDrag.pictureSide)
    }

    /// The drag starts in the event's turn (lead review, 2026-10-25): its pasteboard holds the file URL and
    /// name at once and answers the image types from the off-main read's bytes and TIFF; it never reads, decodes
    /// or encodes the file on the main thread.
    @Test func theDragPasteboardAnswersFromTheOffMainBytesAndNeverReads() async throws {
        let file = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).png")
        let pasteboard = AgentPaneFileDragPasteboard(file: file)
        let item = pasteboard.item()
        #expect(item.string(forType: .fileURL) == file.absoluteString)
        #expect(pasteboard.imageTypes == [NSPasteboard.PasteboardType(UTType.png.identifier), .tiff])
        // Asked before the read ended: no data, and no read on the main thread (the file does not even exist).
        #expect(pasteboard.data(for: NSPasteboard.PasteboardType(UTType.png.identifier)) == nil)
        // 640 x 480 pixels: above the main thread's image gate, so a decode or an encode here would be a site.
        let image = await Self.pasteboardImage(try Self.png(width: 640, height: 480))
        pasteboard.image = image
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            #expect(pasteboard.data(for: NSPasteboard.PasteboardType(UTType.png.identifier)) == image.data)
            #expect(pasteboard.data(for: .tiff) == image.tiff)
        }
        await table.flush()
        #expect(image.tiff != nil)
        #expect(table.sites.isEmpty, "the pasteboard decoded on the main thread: \(table.sites)")
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

        #expect(contents.image == nil)
        #expect(contents.picture == nil)
    }
}
#endif
