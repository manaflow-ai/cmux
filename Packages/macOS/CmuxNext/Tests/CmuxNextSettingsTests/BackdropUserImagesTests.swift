import AppKit
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The person's own background (cx-t2x.8): a chosen or dropped image is copied into the
/// backgrounds folder, listed in the picker after the art, and saved to cmux.json as a `file:` id
/// that reads back as that image.
@Suite struct BackdropUserImagesTests {
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("backdrop-own-\(UUID().uuidString)", isDirectory: true)
    }

    private static func png(named name: String, in folder: URL, side: Int = 4) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let url = folder.appendingPathComponent(name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test func aChosenImageIsCopiedListedAndSaved() throws {
        let elsewhere = Self.folder()
        let backgrounds = Self.folder()
        defer {
            try? FileManager.default.removeItem(at: elsewhere)
            try? FileManager.default.removeItem(at: backgrounds)
        }
        let original = try Self.png(named: "Harbor at dusk.png", in: elsewhere)
        let images = BackdropUserImages(folder: backgrounds)

        let chosen = try images.adopt(original)
        // The same image again adds nothing; another image of the same name gets a free name.
        #expect(try images.adopt(original) == chosen)
        let other = try Self.png(named: "Harbor at dusk.png", in: elsewhere.appendingPathComponent("other"), side: 8)
        let again = try images.adopt(other)
        guard case .file(let path) = chosen, case .file(let secondPath) = again else {
            Issue.record("a chosen image is not a file background: \(chosen)")
            return
        }
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == backgrounds.resolvingSymlinksInPath().path)
        #expect(FileManager.default.contentsEqual(atPath: path, andPath: original.path))
        #expect(FileManager.default.contentsEqual(atPath: secondPath, andPath: other.path))
        #expect(URL(fileURLWithPath: secondPath).lastPathComponent == "Harbor at dusk 2.png")
        #expect(chosen.title == "Harbor at dusk")
        // Downloaded art in the same folder is art, not one of the person's images, and so is a
        // download of a work since taken out of the set.
        try Data("art".utf8).write(to: backgrounds.appendingPathComponent("\(BackdropArt.allCases[0].rawValue).avif"))
        try Data("art".utf8).write(to: backgrounds.appendingPathComponent("goya-witches-sabbath.avif"))

        let catalog = BackdropCatalog(systemDirectory: elsewhere.appendingPathComponent("none"),
                                      userImages: images)
        let own = catalog.choices.filter { if case .file = $0 { return true } else { return false } }
        #expect(Set(own) == [chosen, again])
        #expect(catalog.choices.firstIndex(of: chosen)! > catalog.choices.lastIndex { if case .art = $0 { true } else { false } }!)
        #expect(images.contains(chosen))
        #expect(!images.contains(.file(path: backgrounds.resolvingSymlinksInPath().appendingPathComponent("goya-witches-sabbath.avif").path)))
        #expect(!images.contains(.file(path: original.path)))
        // An id cannot reach outside the folder through `..` or a link inside it.
        let folderPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        #expect(!images.contains(.file(path: folderPath + "/../" + original.lastPathComponent)))
        let link = URL(fileURLWithPath: folderPath).appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(!images.contains(.file(path: link.path)))
        #expect(!images.list().contains(.file(path: link.path)))

        let root = JSONValue.object(["appearance": .object(["background": .string(chosen.id)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.backdropSelection == chosen)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("appearance.") })
        #expect(BackdropSelectionSetting.accepts(.string(chosen.id)))
        #expect(!BackdropSelectionSetting.accepts(.string("file:relative.png")))
    }
}
