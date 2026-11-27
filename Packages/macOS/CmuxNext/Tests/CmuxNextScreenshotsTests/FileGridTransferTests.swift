import AppKit
import CmuxNextFileGrid
import Foundation
import Testing
import UniformTypeIdentifiers

/// What a drag or Copy out of the grid offers, and what a drop into it holds.
@Suite(.serialized) struct FileGridTransferTests {
    static func item(_ url: URL, kind: FileGridMediaKind? = nil) -> FileGridItem {
        FileGridItem(url: url, kind: kind, size: 4, modified: Date(), sourceID: "s")
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

    @Test func movieLengthsReadLikeAPlayer() {
        #expect(FileGridDurationText().string(for: 7.4) == "0:07")
        #expect(FileGridDurationText().string(for: 62) == "1:02")
        #expect(FileGridDurationText().string(for: 3723) == "1:02:03")
    }
}

/// A drop as a value: a fleet ci-step Mac has no pasteboard server.
struct Drop: FileGridDropContents {
    var droppedFileURLs: [URL] = []
    var droppedImage: NSImage?
    var holdsImage: Bool { droppedImage != nil }
}
