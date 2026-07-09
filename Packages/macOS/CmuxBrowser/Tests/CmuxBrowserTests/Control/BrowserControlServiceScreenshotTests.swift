import AppKit
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserControlService screenshot")
struct BrowserControlServiceScreenshotTests {
    let service = BrowserControlService()

    private func solidImage(width: Int, height: Int) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    @Test("pngData encodes an image to decodable PNG bytes")
    func pngDataEncodes() throws {
        let data = try #require(service.pngData(from: solidImage(width: 4, height: 4)))
        // PNG signature.
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Round-trips back into an image.
        #expect(NSBitmapImageRep(data: data) != nil)
    }

    @Test("persistScreenshot writes a file with the surface-prefixed name and a matching file URL")
    func persistWritesFile() throws {
        let surfaceId = UUID()
        let bytes = try #require(service.pngData(from: solidImage(width: 2, height: 2)))
        let result = service.persistScreenshot(imageData: bytes, surfaceId: surfaceId)

        let path = try #require(result.filePath)
        let urlString = try #require(result.fileURL)

        let written = try #require(FileManager.default.contents(atPath: path))
        #expect(written == bytes)

        let filename = (path as NSString).lastPathComponent
        let shortSurfaceId = String(surfaceId.uuidString.prefix(8))
        #expect(filename.hasPrefix("surface-\(shortSurfaceId)-"))
        #expect(filename.hasSuffix(".png"))
        #expect(urlString == URL(fileURLWithPath: path).absoluteString)
        #expect(path.contains("cmux-browser-screenshots"))

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("pruneTemporaryFiles keeps only the most recent files by count")
    func prunesByCount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-screenshots-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var urls: [URL] = []
        let now = Date()
        for index in 0..<5 {
            let url = dir.appendingPathComponent("file-\(index).png", isDirectory: false)
            try Data([UInt8(index)]).write(to: url)
            // Stagger modification dates so newest-first ordering is deterministic.
            let date = now.addingTimeInterval(TimeInterval(index))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            urls.append(url)
        }

        service.pruneTemporaryFiles(in: dir, keepingMostRecent: 2, maxAge: 24 * 60 * 60)

        let remaining = Set(
            (try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))
                .map { $0.lastPathComponent }
        )
        // The two newest (index 3 and 4) survive; the three oldest are removed.
        #expect(remaining == ["file-3.png", "file-4.png"])
    }

    @Test("pruneTemporaryFiles removes files older than maxAge regardless of count")
    func prunesByAge() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-screenshots-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fresh = dir.appendingPathComponent("fresh.png", isDirectory: false)
        let stale = dir.appendingPathComponent("stale.png", isDirectory: false)
        try Data([0]).write(to: fresh)
        try Data([1]).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-48 * 60 * 60)],
            ofItemAtPath: stale.path
        )

        service.pruneTemporaryFiles(in: dir, keepingMostRecent: 50, maxAge: 24 * 60 * 60)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}
