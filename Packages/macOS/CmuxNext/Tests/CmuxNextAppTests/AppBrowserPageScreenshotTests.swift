import CmuxNextControl
@testable import CmuxNextApp
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// An element screenshot is the element's rectangle cut from the viewport
/// snapshot, scaled from CSS pixels to the snapshot's pixels, and encodes
/// as a PNG.
@MainActor
@Suite struct AppBrowserPageScreenshotTests {
    func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func cropsTheClipAtTheSnapshotScale() throws {
        // A 2x snapshot of an 800x600 CSS viewport.
        let snapshot = try image(width: 1600, height: 1200)
        let clip = BrowserPageClip(x: 10, y: 20, width: 30, height: 40, viewportWidth: 800, viewportHeight: 600)
        let cropped = try AppBrowserPage.crop(snapshot, to: clip)
        #expect(cropped.width == 60)
        #expect(cropped.height == 80)
    }

    @Test func aClipOutsideTheSnapshotIsRefused() throws {
        let snapshot = try image(width: 800, height: 600)
        let clip = BrowserPageClip(x: 900, y: 0, width: 30, height: 40, viewportWidth: 800, viewportHeight: 600)
        #expect(throws: ControlError.self) { try AppBrowserPage.crop(snapshot, to: clip) }
    }

    @Test func encodesAPNGAndSavesItToATemporaryFile() async throws {
        let data = try #require(await AppBrowserPage.pngData(try image(width: 4, height: 3)))
        let path = try await AppBrowserPage.save(data, tabID: "tab_0123")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(path.hasSuffix(".png"))
        #expect(path.contains("cmux-browser-screenshots/tab_0123-"))
        #expect(FileManager.default.contents(atPath: path) == data)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 4)
    }

    /// Screenshots saved without `--out` used to accumulate in the temporary
    /// directory forever; each save now prunes old and surplus files.
    @Test func savingPrunesOldAndSurplusScreenshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for index in 0..<5 {
            let file = directory.appendingPathComponent("shot-\(index).png")
            try Data([1]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(-index * 60))], ofItemAtPath: file.path)
        }
        let old = directory.appendingPathComponent("old.png")
        try Data([1]).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: old.path)
        let other = directory.appendingPathComponent("notes.txt")
        try Data([1]).write(to: other)

        AppBrowserPage.prune(directory, keeping: 3, newerThan: now.addingTimeInterval(-3600))
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == ["notes.txt", "shot-0.png", "shot-1.png", "shot-2.png"])
    }
}
