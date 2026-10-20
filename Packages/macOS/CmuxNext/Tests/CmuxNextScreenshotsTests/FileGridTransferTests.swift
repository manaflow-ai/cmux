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

    /// Copy offers every file (a lone picture with its bytes); Copy Path is one path per line.
    @Test func copyOffersEveryFileAndCopyPathIsOnePathPerLine() throws {
        let folder = try TemporaryFolder()
        let first = try folder.write("a.png")
        let second = try folder.write("b.png")
        let writer = FileGridPasteboard()
        let items = writer.pasteboardItems(for: [Self.item(first), Self.item(second)])
        #expect(items.map { $0.string(forType: .fileURL) } == [first.absoluteString, second.absoluteString])
        #expect(items.allSatisfy { $0.types == [.fileURL] }, "two files: no picture bytes")
        let lone = writer.pasteboardItems(for: [Self.item(first)])
        #expect(lone.first?.types.contains(NSPasteboard.PasteboardType(UTType.png.identifier)) == true)
        #expect(writer.pathsText(for: [Self.item(first), Self.item(second)]) == "\(first.path)\n\(second.path)")
    }

    @Test func aDroppedFileIsCopiedInUnderAFreeName() throws {
        let source = try TemporaryFolder()
        let target = try TemporaryFolder()
        let file = try source.write("Shot.png")
        try target.write("Shot.png")
        let drop = Drop(droppedFileURLs: [file])
        let importer = FileGridDropImporter()
        #expect(importer.canImport(drop))
        #expect(!importer.canImport(Drop()))
        let saved = try importer.importItems(from: drop, into: target.url)
        #expect(saved.map(\.lastPathComponent) == ["Shot 2.png"])
        #expect(FileManager.default.fileExists(atPath: file.path), "a drop copies, never moves")
    }

    /// A file dropped from the grid's own folder is not copied onto itself.
    @Test func aFileFromTheSameFolderIsNotCopiedAgain() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("Shot.png")
        let saved = try FileGridDropImporter().importItems(from: Drop(droppedFileURLs: [file]), into: folder.url)
        #expect(saved.isEmpty)
    }

    @Test func droppedPictureDataBecomesATimeNamedPNG() throws {
        let target = try TemporaryFolder()
        let image = NSImage(size: CGSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let drop = Drop(droppedImage: image)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let importer = FileGridDropImporter(now: { date })
        #expect(importer.canImport(drop))
        let saved = try importer.importItems(from: drop, into: target.url)
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

/// A drop as a value: a fleet ci-step Mac has no pasteboard server.
private struct Drop: FileGridDropContents {
    var droppedFileURLs: [URL] = []
    var droppedImage: NSImage?
    var holdsImage: Bool { droppedImage != nil }
}
