import AppKit
@testable import CmuxNextDesign
import Testing

/// #17587: the panes' last frames (terminals', agent pages') are read and decoded off the main
/// thread from the top of `main`; the launch window's pane builds only take them. Before, each
/// pane build read and decoded its JPEG or PNG on the main thread, before the first window frame.
@MainActor @Suite struct SavedFrameDirectoryTests {
    /// Records the `launch_read_on_main.<name>` marks a directory reports (only ever on the main thread).
    final class Marks {
        private(set) var all: [String] = []
        var record: @Sendable (String) -> Void {
            { name in MainActor.assumeIsolated { self.all.append(name) } } // main-proof: a directory reports only reads made on the main thread
        }
    }

    /// An 8x6 pixel PNG.
    static func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// A directory saved with `files`.
    static func saved(_ files: [String: Data]) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "saved-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        SavedFrameDirectory.write(files, to: url)
        return url
    }

    @Test func aFrameDecodedInTheBackgroundIsTakenWithNoReadOnTheMainThread() async throws {
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): try Self.png()])
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = Marks()
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames", readOnMain: marks.record)
        await frames.backgroundReadFinished()
        let frame = try #require(frames.take("tab_a"))
        #expect(frame.scale == 2)
        #expect(frame.size == NSSize(width: 4, height: 3))
        #expect(marks.all.isEmpty, "the pane build only took the decoded frame")
        #expect(frames.take("tab_a") == nil, "a frame is handed out once per launch")
    }

    @Test func aKeyWithNoFileIsNotLookedForOnceListed() async throws {
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 1, ext: "png"): try Self.png()])
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = Marks()
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames", readOnMain: marks.record)
        await frames.backgroundReadFinished()
        #expect(frames.take("tab_b") == nil)
        #expect(frames.take("../tab_a") == nil, "a key that is not a file name never becomes a path")
        #expect(marks.all.isEmpty)
    }

    @Test func releaseDropsTheFramesNoPaneTook() async throws {
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): try Self.png()])
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = Marks()
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames", readOnMain: marks.record)
        await frames.backgroundReadFinished()
        frames.release()
        #expect(frames.take("tab_a") == nil, "after the launch settled nothing is read, on the main thread or off it")
        #expect(marks.all.isEmpty)
    }

    @Test func aLargerFileIsNotRead() async throws {
        let png = try Self.png()
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): png])
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = SavedFrameDirectory(url: url, maximumBytes: png.count - 1)
        await frames.backgroundReadFinished()
        #expect(frames.take("tab_a") == nil)
    }

    @Test func aSaveReplacesTheWholeSet() async throws {
        let png = try Self.png()
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): png])
        defer { try? FileManager.default.removeItem(at: url) }
        SavedFrameDirectory.write([SavedFrameDirectory.fileName("tab_b", scale: 2, ext: "png"): png], to: url)
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20)
        await frames.backgroundReadFinished()
        #expect(frames.take("tab_a") == nil)
        #expect(frames.take("tab_b") != nil)
    }
}
