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

    private static func png(named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
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
        let again = try images.adopt(original)
        guard case .file(let path) = chosen, case .file(let secondPath) = again else {
            Issue.record("a chosen image is not a file background: \(chosen)")
            return
        }
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == backgrounds.standardizedFileURL)
        #expect(FileManager.default.contentsEqual(atPath: path, andPath: original.path))
        #expect(URL(fileURLWithPath: secondPath).lastPathComponent == "Harbor at dusk 2.png")
        #expect(chosen.title == "Harbor at dusk")
        // Downloaded art in the same folder is art, not one of the person's images.
        try Data("art".utf8).write(to: backgrounds.appendingPathComponent("\(BackdropArt.allCases[0].rawValue).avif"))

        let catalog = BackdropCatalog(systemDirectory: elsewhere.appendingPathComponent("none"), fileManager: .default,
                                      userImages: images)
        let own = catalog.choices.filter { if case .file = $0 { return true } else { return false } }
        #expect(Set(own) == [chosen, again])
        #expect(catalog.choices.firstIndex(of: chosen)! > catalog.choices.lastIndex { if case .art = $0 { true } else { false } }!)
        #expect(images.contains(chosen))
        #expect(!images.contains(.file(path: original.path)))

        let root = JSONValue.object(["appearance": .object(["background": .string(chosen.id)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.backdropSelection == chosen)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("appearance.") })
        #expect(BackdropSelectionSetting.accepts(.string(chosen.id)))
        #expect(!BackdropSelectionSetting.accepts(.string("file:relative.png")))
    }
}
