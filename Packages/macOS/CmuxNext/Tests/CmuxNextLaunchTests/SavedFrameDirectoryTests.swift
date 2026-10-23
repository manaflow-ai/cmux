import AppKit
@testable import CmuxNextLaunch
import Testing

/// #17587: the panes' last frames (terminals', agent pages') are read and decoded off the main
/// thread from the top of `main`; the launch window's pane builds only take them. Before, each
/// pane build read and decoded its JPEG or PNG on the main thread, before the first window frame.
@MainActor @Suite struct SavedFrameDirectoryTests {
    /// Records the `launch_read_on_main.<name>` marks a directory reports (only ever on the main thread).
    /// `@MainActor` itself: a nested type does not take the suite's isolation, and this target has
    /// no main-actor default (daemon settings), so only a global-actor class is `Sendable` for the
    /// `@Sendable` closure below to capture.
    @MainActor final class Marks {
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

    /// A listed frame whose background decode failed is not read again by its taker (on the main
    /// thread, unmarked): the failure is recorded, so a later good file in its place is not looked at.
    @Test func aListedFrameThatFailedToDecodeIsNotReadAgain() async throws {
        let file = SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png")
        let url = Self.saved([file: Data("not an image".utf8)])
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = Marks()
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames", readOnMain: marks.record)
        await frames.backgroundReadFinished()
        try Self.png().write(to: url.appending(path: file))
        #expect(frames.take("tab_a") == nil, "the taker did not read the file again")
        #expect(marks.all.isEmpty)
    }

    /// Taking one pane's frame leaves the others: the frames stay until ``SavedFrameDirectory/release()``,
    /// which the launch calls once every restored pane presented (not at the first pane).
    @Test func aSecondPaneStillTakesItsFrameAfterTheFirst() async throws {
        let png = try Self.png()
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): png,
                              SavedFrameDirectory.fileName("tab_b", scale: 2, ext: "png"): png])
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = Marks()
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames", readOnMain: marks.record)
        await frames.backgroundReadFinished()
        #expect(frames.take("tab_a") != nil)
        #expect(frames.take("tab_b") != nil)
        #expect(marks.all.isEmpty)
    }

    /// A pane build that takes its frame before the background task decoded it gets the frame: it
    /// waits for the decode running, or decodes it itself; a later take finds it handed out.
    @Test func aFrameTakenBeforeTheBackgroundDecodeFinishedIsStillTheFrame() async throws {
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): try Self.png()])
        defer { try? FileManager.default.removeItem(at: url) }
        let marks = Marks()
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames", readOnMain: marks.record)
        let frame = try #require(frames.take("tab_a"))
        #expect(frame.size == NSSize(width: 4, height: 3))
        await frames.backgroundReadFinished()
        #expect(frames.take("tab_a") == nil, "handed out once; the background task did not decode it a second time for nobody")
        #expect(marks.all.count <= 1, "at most one mark: the take on the main thread waited or decoded once")
    }

    /// The panes the first window shows decode first (`prioritize`, from the launch snapshot), in
    /// its order, whether the hint comes before or after the listing; the other windows' frames after.
    @Test(arguments: [true, false])
    func theFirstWindowsFramesDecodeFirst(hintBeforeListing: Bool) {
        let file = URL(fileURLWithPath: "/dev/null")
        var state = SavedFrameDirectoryState()
        if hintBeforeListing { state.prioritize(["tab_z", "tab_m"]) }
        state.listed(["tab_a": .init(file: file, scale: 2), "tab_m": .init(file: file, scale: 2),
                      "tab_z": .init(file: file, scale: 2), "tab_b": .init(file: file, scale: 2)])
        if !hintBeforeListing { state.prioritize(["tab_z", "tab_m", "tab_gone"]) }
        let order = (0..<5).compactMap { _ in state.claimNext(lane: 0)?.key }
        #expect(order == ["tab_z", "tab_m", "tab_a", "tab_b"])
    }

    /// A frame a pane build claimed is not decoded again by a lane, and a release stops the lanes.
    @Test func aClaimedFrameIsSkippedAndAReleaseStopsTheLanes() {
        let file = URL(fileURLWithPath: "/dev/null")
        var state = SavedFrameDirectoryState()
        state.listed(["tab_a": .init(file: file, scale: 2), "tab_b": .init(file: file, scale: 2), "tab_c": .init(file: file, scale: 2)])
        state.entries?["tab_a"]?.phase = .taken
        #expect(state.claimNext(lane: 1)?.key == "tab_b")
        state.release()
        #expect(state.claimNext(lane: 1) == nil)
        state.decoded("tab_b", nil)
        #expect(state.entries?["tab_b"] == nil, "a decode that ends after the release keeps nothing")
    }

    @Test func aLargerFileIsNotRead() async throws {
        let png = try Self.png()
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): png])
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = SavedFrameDirectory(url: url, maximumBytes: png.count - 1, name: "test_frames", readOnMain: { _ in })
        await frames.backgroundReadFinished()
        #expect(frames.take("tab_a") == nil)
    }

    @Test func aSaveReplacesTheWholeSet() async throws {
        let png = try Self.png()
        let url = Self.saved([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): png])
        defer { try? FileManager.default.removeItem(at: url) }
        SavedFrameDirectory.write([SavedFrameDirectory.fileName("tab_b", scale: 2, ext: "png"): png], to: url)
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames", readOnMain: { _ in })
        await frames.backgroundReadFinished()
        #expect(frames.take("tab_a") == nil)
        #expect(frames.take("tab_b") != nil)
    }
}
