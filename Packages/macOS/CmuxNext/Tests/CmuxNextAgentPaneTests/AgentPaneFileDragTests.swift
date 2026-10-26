#if DEBUG
import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing
import UniformTypeIdentifiers

/// A drag of a file out of an agent chat starts at once with no read, and reads an image's bytes and
/// picture, or the file's icon, on the app's blocking-work lanes after the start
/// (plans/cmux-next/threading-model.md, p02-threads-006). Each test binds its own blocking table, so a read
/// or a Launch Services query on the main thread shows as a site.
@MainActor @Suite(.serialized)
struct AgentPaneFileDragTests {
    private let work = BackgroundWork(label: "test.file-drag")

    /// An icon source that counts its calls, and the calls made on the main thread.
    private final class IconQueries: Sendable {
        let calls = Atomic<Int>(0)
        let onMain = Atomic<Int>(0)
        var source: AgentPaneFileDrag.IconSource {
            { [self] _ in
                calls.wrappingAdd(1, ordering: .relaxed)
                if Thread.isMainThread { onMain.wrappingAdd(1, ordering: .relaxed) }
                return NSImage(size: AgentPaneFileDrag.iconSize)
            }
        }
    }

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
            await AgentPaneFileDrag(work: work).contents(of: file)
        }
        await table.flush()

        #expect(table.sites.isEmpty, "a drag read the file on the main thread: \(table.sites)")
        #expect(contents.data == png)
        let picture = try #require(contents.picture)
        #expect(picture.size == CGSize(width: 160, height: 80))
        #expect(contents.icon == nil)
    }

    /// The drag asked Launch Services for the file's icon on the main thread, in the event's turn
    /// (p02-threads-006). Now the turn's item (what `start` hands `beginDraggingSession`) asks the icon source
    /// nothing, and the lane read asks it once, off the main thread.
    @Test func aFilesIconIsAskedForOnTheSystemLaneNotInTheDragsTurn() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let queries = IconQueries()
        let drag = AgentPaneFileDrag(work: work, icon: queries.source)
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))

        let table = BlockingViolationTable(mode: .record)
        let (item, _) = BlockingViolationTable.$scoped.withValue(table) {
            drag.firstItem(file, at: CGPoint(x: 100, y: 100), in: view)
        }
        #expect(queries.calls.load(ordering: .relaxed) == 0, "the drag's turn asked for the file's icon")
        #expect(item.draggingFrame.size == AgentPaneFileDrag.iconSize)
        let contents = await BlockingViolationTable.$scoped.withValue(table) { await drag.contents(of: file) }
        await table.flush()

        #expect(table.sites.isEmpty, "a drag asked for the icon on the main thread: \(table.sites)")
        #expect(queries.calls.load(ordering: .relaxed) == 1)
        #expect(queries.onMain.load(ordering: .relaxed) == 0, "the icon was asked for on the main thread")
        let icon = try #require(contents.icon)
        #expect(icon.size == AgentPaneFileDrag.iconSize)
    }

    /// The real Launch Services icon comes from the system lane, at ``AgentPaneFileDrag/iconSize``.
    @Test func theLaunchServicesIconIsReadOnTheSystemLane() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)

        let table = BlockingViolationTable(mode: .record)
        let contents = await BlockingViolationTable.$scoped.withValue(table) {
            await AgentPaneFileDrag(work: work).contents(of: file)
        }
        await table.flush()

        #expect(table.sites.isEmpty, "a drag asked for the icon on the main thread: \(table.sites)")
        let icon = try #require(contents.icon)
        #expect(icon.size == AgentPaneFileDrag.iconSize)
    }

    /// The turn's generic image is not a template (a drag image is not tinted, so a template symbol drew
    /// black, close to invisible in dark mode), draws in each appearance's label color, and keeps the
    /// symbol's own aspect ratio (a page: taller than wide) inside the ``AgentPaneFileDrag/iconSize`` frame.
    @Test(arguments: [true, false])
    func thePlaceholderShowsInEachAppearanceAndKeepsItsAspect(dark: Bool) throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        let image = AgentPaneFileDrag.placeholder(appearance: appearance, scale: 1)
        #expect(!image.isTemplate)
        #expect(image.size == AgentPaneFileDrag.iconSize)

        let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        var ink: [CGFloat] = []
        var columns = Set<Int>()
        var rows = Set<Int>()
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                ink.append(color.brightnessComponent)
                columns.insert(x)
                rows.insert(y)
            }
        }
        let brightest = try #require(ink.max(), "the placeholder drew nothing")
        let darkest = try #require(ink.min())
        if dark {
            #expect(brightest > 0.7, "the placeholder is dark on a dark background")
        } else {
            #expect(darkest < 0.3, "the placeholder is light on a light background")
        }
        #expect(columns.count < rows.count, "the symbol was stretched to a square")
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

        let contents = await AgentPaneFileDrag(work: work).contents(of: file)

        #expect(contents.data == nil)
        #expect(contents.picture == nil)
    }
}
#endif
