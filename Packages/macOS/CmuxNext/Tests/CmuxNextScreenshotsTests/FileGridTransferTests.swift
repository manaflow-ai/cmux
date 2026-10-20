import AppKit
import CmuxNextFileGrid
import Foundation
import Testing
import UniformTypeIdentifiers

/// Names, drag-out pasteboards and drop-in saves.
@Suite(.serialized) struct FileGridTransferTests {
    static func item(_ url: URL, kind: FileGridMediaKind? = nil) -> FileGridItem {
        FileGridItem(url: url, kind: kind, size: 4, modified: Date(), sourceID: "s")
    }

    @Test func freeNamesCountUpLikeFinder() {
        let taken: Set<String> = ["/f/Shot.png", "/f/Shot 2.png", "/f/notes"]
        let naming = FileGridNaming(exists: { taken.contains($0.path) })
        let folder = URL(fileURLWithPath: "/f", isDirectory: true)
        #expect(naming.free("Shot.png", in: folder).lastPathComponent == "Shot 3.png")
        #expect(naming.free("Other.png", in: folder).lastPathComponent == "Other.png")
        #expect(naming.free("notes", in: folder).lastPathComponent == "notes 2")
    }

    @Test func renameRefusesBadAndTakenNames() throws {
        let naming = FileGridNaming(exists: { $0.lastPathComponent == "taken.png" })
        let file = URL(fileURLWithPath: "/f/a.png")
        #expect(try naming.renamed(file, to: "  b.png ").lastPathComponent == "b.png")
        #expect(try naming.renamed(file, to: "a.png") == file)
        #expect(throws: FileGridNaming.Refusal.exists) { try naming.renamed(file, to: "taken.png") }
        for bad in ["", "  ", "a/b.png", "a:b", ".", ".."] {
            #expect(throws: FileGridNaming.Refusal.invalid) { try naming.renamed(file, to: bad) }
        }
    }

    /// One dragged picture offers its file and its bytes; a multi-file drag offers files only.
    @Test func aDraggedPictureCarriesItsFileAndItsBytes() throws {
        let folder = try TemporaryFolder()
        let png = try folder.write("a.png")
        let writer = FileGridPasteboard()
        let single = writer.pasteboardItem(for: Self.item(png), includeImageData: true)
        #expect(single.string(forType: .fileURL) == png.absoluteString)
        #expect(single.types.contains(NSPasteboard.PasteboardType(UTType.png.identifier)))
        let multi = writer.pasteboardItem(for: Self.item(png), includeImageData: false)
        #expect(multi.types == [.fileURL])
        let movie = writer.pasteboardItem(for: Self.item(try folder.write("a.mov")), includeImageData: true)
        #expect(movie.types == [.fileURL])
    }

    @Test func copyWritesFilesAndCopyPathWritesText() throws {
        let folder = try TemporaryFolder()
        let first = try folder.write("a.png")
        let second = try folder.write("b.png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let writer = FileGridPasteboard()
        writer.write([Self.item(first), Self.item(second)], to: pasteboard)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls?.map(\.lastPathComponent) == ["a.png", "b.png"])
        writer.writePaths([Self.item(first), Self.item(second)], to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "\(first.path)\n\(second.path)")
    }

    @Test func aDroppedFileIsCopiedInUnderAFreeName() throws {
        let source = try TemporaryFolder()
        let target = try TemporaryFolder()
        let file = try source.write("Shot.png")
        try target.write("Shot.png")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let importer = FileGridDropImporter()
        #expect(importer.canImport(pasteboard))
        let saved = try importer.importItems(from: pasteboard, into: target.url)
        #expect(saved.map(\.lastPathComponent) == ["Shot 2.png"])
        #expect(FileManager.default.fileExists(atPath: file.path), "a drop copies, never moves")
    }

    @Test func droppedPictureDataBecomesATimeNamedPNG() throws {
        let target = try TemporaryFolder()
        let image = NSImage(size: CGSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let importer = FileGridDropImporter(now: { date })
        let saved = try importer.importItems(from: pasteboard, into: target.url)
        #expect(saved.map(\.lastPathComponent) == [FileGridDropImporter.droppedName(at: date)])
        let data = try Data(contentsOf: try #require(saved.first))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "a PNG")
    }

    @Test func movieLengthsReadLikeAPlayer() {
        #expect(FileGridDurationText().string(for: 7.4) == "0:07")
        #expect(FileGridDurationText().string(for: 62) == "1:02")
        #expect(FileGridDurationText().string(for: 3723) == "1:02:03")
    }
}
