import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// Markdown in Home shows only the attachment pictures Home wrote (``HomeMarkdownImages``), and
/// the Markdown layout and the row bitmaps ask for them off the main thread: the provider is
/// Sendable, its pictures behind one lock.
@Suite struct HomeMarkdownImagesTests {
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-md-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real 4×3 PNG named `name` in `folder`.
    private static func png(_ name: String, in folder: URL) throws -> URL {
        let rep = try #require(NSBitmapImageRep.owned(pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let file = folder.appendingPathComponent(name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        return file
    }

    @Test func aPictureInTheFolderDecodesOnceAndIsKept() throws {
        let folder = try Self.folder()
        let file = try Self.png("hash1.png", in: folder)
        let images = HomeMarkdownImages(directory: folder)
        let first = try #require(images.markdownImage(source: file.absoluteString, alt: "a"))
        #expect(first.width == 4 && first.height == 3)
        // The second ask is the kept picture (a new decode would be another image).
        #expect(images.markdownImage(source: file.absoluteString, alt: "a") === first)
    }

    @Test func anythingOutsideTheFolderGivesNoPicture() throws {
        let folder = try Self.folder()
        let other = try Self.folder()
        let outside = try Self.png("elsewhere.png", in: other)
        let images = HomeMarkdownImages(directory: folder)
        #expect(images.markdownImage(source: outside.absoluteString, alt: "") == nil)
        #expect(images.markdownImage(source: "https://example.com/a.png", alt: "") == nil)
        #expect(images.markdownImage(source: folder.appendingPathComponent("missing.png").absoluteString, alt: "") == nil)
        // A path that climbs out of the folder is resolved first, so it is outside too.
        let climbing = folder.appendingPathComponent("../\(other.lastPathComponent)/elsewhere.png")
        #expect(images.markdownImage(source: climbing.absoluteString, alt: "") == nil)
    }

    /// Many threads ask at once (rows drawn in parallel): every answer is the one kept picture.
    @Test func concurrentAsksAllGetThePicture() async throws {
        let folder = try Self.folder()
        let file = try Self.png("hash2.png", in: folder)
        let images = HomeMarkdownImages(directory: folder)
        let source = file.absoluteString
        let sizes = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<64 {
                group.addTask { images.markdownImage(source: source, alt: "")?.width ?? 0 }
            }
            var out: [Int] = []
            for await width in group { out.append(width) }
            return out
        }
        #expect(sizes.count == 64)
        #expect(sizes.allSatisfy { $0 == 4 })
        let kept = try #require(images.markdownImage(source: source, alt: ""))
        #expect(images.markdownImage(source: source, alt: "") === kept)
    }
}
