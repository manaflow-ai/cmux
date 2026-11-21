import CmuxNextDesign
import Foundation
import Testing

/// A folder shuffle turns through the pictures in its subfolders too (Leo, 2026-11-16: "but i have a
/// broader folder that has more stuff?"): a wallpaper folder with nothing at its top and everything
/// in nested folders still shuffles, in relative-path order, within a bound.
@Suite struct BackdropFolderPicturesTests {
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backdrop-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func touch(_ relative: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }

    /// The relative paths a listing names, in its order.
    private static func relative(_ pictures: [BackdropSelection], to folder: URL) -> [String] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return pictures.map { picture in
            guard case .file(let path) = picture else { return "not a file: \(picture.id)" }
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : "outside: \(path)"
        }
    }

    @Test func nestedPicturesAreListedByRelativePath() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Nothing at the top, pictures up to four folders down, like ~/Pictures/Wallpapers.
        for name in ["Nature/Mountains/Alps/Winter/peak.jpg", "Nature/sea.png", "Art/b.heic", "Art/a.webp",
                     "Nature/notes.txt", ".hidden/secret.png", "Art/.dot.png", "Viewer.app/Contents/inside.jpg",
                     "Art/folder.png/inner.jpg"] {
            try Self.touch(name, in: folder)
        }
        // A link back up the tree would loop; links are never followed, so it is just skipped.
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Nature/loop"), withDestinationURL: folder)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Art/link.png"),
                                                   withDestinationURL: folder.appendingPathComponent("Art/a.webp"))

        let pictures = BackdropFolderPictures(folder: folder).list()
        #expect(Self.relative(pictures, to: folder) == [
            "Art/a.webp", "Art/b.heic", "Art/folder.png/inner.jpg", "Nature/Mountains/Alps/Winter/peak.jpg", "Nature/sea.png",
        ])
        // The same order every time.
        #expect(BackdropFolderPictures(folder: folder).list() == pictures)
    }

    @Test func theWalkStopsAtItsBounds() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.touch("top.png", in: folder)
        try Self.touch("1/2/3/deep.png", in: folder)
        for index in 0..<10 { try Self.touch("many/\(index).jpg", in: folder) }
        let pictures = BackdropFolderPictures(folder: folder)

        // Two folders down: `1/2/3/deep.png` is three down and not read.
        #expect(!Self.relative(pictures.list(maxDepth: 2), to: folder).contains("1/2/3/deep.png"))
        #expect(Self.relative(pictures.list(maxDepth: 3), to: folder).contains("1/2/3/deep.png"))
        // At most this many pictures, the same ones each time.
        let capped = pictures.list(maxPictures: 4)
        #expect(capped.count == 4)
        #expect(pictures.list(maxPictures: 4) == capped)
        // A bound on entries looked at stops the walk too, pictures or not.
        #expect(pictures.list(maxEntries: 3).count < 3)
        #expect(pictures.list().count == 12)
        #expect(BackdropFolderPictures.maxDepth >= 8 && BackdropFolderPictures.maxPictures >= 5_000)
    }
}
