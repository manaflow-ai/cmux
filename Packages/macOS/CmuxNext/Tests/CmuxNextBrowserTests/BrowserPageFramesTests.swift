@testable import CmuxNextBrowser
import CmuxNextWakeups
import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing

/// Browser tabs' last pictures on disk for the next launch (`BrowserPageFrames`; Leo 2026-11-22, constant rerenders
/// on every page after a relaunch): a write replaces the tab's picture, the folder keeps its budget least recently
/// written out first, a closed tab's picture goes, a quit stops every write posted before its own, and the launch
/// read hands each picture out once.
@MainActor @Suite(.serialized) struct BrowserPageFramesTests {
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "browser-page-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func picture(_ red: CGFloat = 0.2, size: Int = 200) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // Noise, so the JPEG has a size worth a budget.
        for index in 0..<400 {
            context.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: CGFloat(index % 11) / 11, blue: CGFloat(index % 13) / 13, alpha: 1))
            context.fill(CGRect(x: (index * 37) % size, y: (index * 53) % size, width: 5, height: 5))
        }
        return try #require(context.makeImage())
    }

    private static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func fileNamesAreSharedWithTerminalFrames() {
        #expect(LaunchFrameFiles.name("tab_ab12", scale: 2) == "tab_ab12@2x.jpg")
        #expect(LaunchFrameFiles.name("tab_ab12", scale: 9) == "tab_ab12@3x.jpg")
        #expect(LaunchFrameFiles.owner(of: "tab_ab12@1x.jpg") == "tab_ab12")
        #expect(LaunchFrameFiles.owner(of: "tab_ab12@2x.jpg.sb-1234") == nil, "an atomic write's temporary file is no frame")
        #expect(LaunchFrameFiles.owner(of: "tab_ab12@4x.jpg") == nil)
        #expect(!LaunchFrameFiles.isFileSafe("../escape"))
        #expect(LaunchFrameFiles.isFileSafe("tab_0f9e-1"))
    }

    /// cmux#57419: a picture keeps its pixels per point (its file name's), so a stand-in draws it at its own size on a
    /// display of another scale; and a read right after a save gets the new picture, never the file it replaces (the
    /// read's lane can run before the write's).
    @Test func aPictureKeepsItsScaleAndAReadAfterASaveGetsTheNewOne() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(LaunchFrameFiles.scale(of: "tab_ab12@3x.jpg") == 3)
        #expect(LaunchFrameFiles.scale(of: "tab_ab12@2x.jpg.sb-1234") == nil)
        let old = try #require(BrowserPageFrames.encoded(try Self.picture(0.1, size: 100)))
        BrowserPageFrames.write(old, key: "tab_a", scale: 1, to: folder, capacity: 1 << 20)
        let frames = BrowserPageFrames(directory: folder), work = BackgroundWork()
        await frames.prefetch(on: work).value
        let saved = try Self.picture(0.9, size: 300)
        frames.save(saved, for: "tab_a", scale: 3)
        let read = try #require(await frames.lastFrame("tab_a"))
        #expect(read.image.width == 300 && read.scale == 3, "a read right after a save got the picture it replaced")
        // The write's own lane slot runs in order: an item posted after it runs once it is written.
        await withCheckedContinuation { (written: CheckedContinuation<Void, Never>) in work.post(.bestEffort, mayBlock: .files) { written.resume() } }
        #expect(BrowserPageFrames.readFrame("tab_a", in: folder)?.scale == 3, "the file is not the new picture's")
        let nextRun = BrowserPageFrames(directory: folder)
        await nextRun.prefetch(on: BackgroundWork()).value
        let taken = try #require(nextRun.takeFrame("tab_a"))
        #expect(taken.image.width == 300 && taken.scale == 3, "the next run lost the picture's scale")
    }

    @Test func aWriteReplacesTheTabsPictureAndAReadHandsItOutOnce() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try #require(BrowserPageFrames.encoded(try Self.picture()))
        BrowserPageFrames.write(data, key: "tab_a", scale: 1, to: folder, capacity: 1 << 20)
        BrowserPageFrames.write(data, key: "tab_a", scale: 2, to: folder, capacity: 1 << 20)
        #expect(Self.names(in: folder) == ["tab_a@2x.jpg"], "one file per tab")

        let frames = BrowserPageFrames(directory: folder)
        await frames.prefetch(on: BackgroundWork()).value
        #expect(frames.hasPicture("tab_a"))
        let image = try #require(frames.take("tab_a"))
        #expect(image.width == 200)
        #expect(frames.take("tab_a") == nil, "handed out once: the live page draws from then on")
        #expect(frames.take("tab_none") == nil)
    }

    @Test func theFolderKeepsItsBudgetLeastRecentlyWrittenOutFirst() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try #require(BrowserPageFrames.encoded(try Self.picture()))
        let capacity = data.count * 2 + data.count / 2
        for key in ["tab_1", "tab_2", "tab_3"] {
            BrowserPageFrames.write(data, key: key, scale: 2, to: folder, capacity: capacity)
            Thread.sleep(forTimeInterval: 0.02)  // distinct modification dates
        }
        #expect(Self.names(in: folder) == ["tab_2@2x.jpg", "tab_3@2x.jpg"], "the oldest went past the budget")
        #expect(BrowserPageFrames.readAll(in: folder, capacity: capacity).keys.sorted() == ["tab_2", "tab_3"])
        #expect(BrowserPageFrames.readAll(in: folder, capacity: data.count).keys.sorted() == ["tab_3"], "the read keeps the budget too, newest first")
    }

    @Test func aClosedTabsPictureGoes() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try #require(BrowserPageFrames.encoded(try Self.picture()))
        BrowserPageFrames.write(data, key: "tab_gone", scale: 2, to: folder, capacity: 1 << 20)
        BrowserPageFrames.write(data, key: "tab_kept", scale: 2, to: folder, capacity: 1 << 20)
        let work = BackgroundWork()
        let frames = BrowserPageFrames(directory: folder)
        await frames.prefetch(on: work).value
        frames.remove("tab_gone")
        #expect(!frames.hasPicture("tab_gone"))
        try await until { Self.names(in: folder) == ["tab_kept@2x.jpg"] }
    }

    @Test func aSaveWritesAndReplacesTheLastRunsPictureInMemory() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try #require(BrowserPageFrames.encoded(try Self.picture()))
        BrowserPageFrames.write(data, key: "tab_a", scale: 2, to: folder, capacity: 1 << 20)
        let frames = BrowserPageFrames(directory: folder)
        await frames.prefetch(on: BackgroundWork()).value
        frames.save(try Self.picture(0.9), for: "tab_a", scale: 1)
        #expect(!frames.hasPicture("tab_a"), "a picture of this run is not the last run's")
        try await until { Self.names(in: folder) == ["tab_a@1x.jpg"] }
    }

    @Test func aQuitWritesThePagesOnScreenAndStopsLaterWrites() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = BrowserPageFrames(directory: folder)
        await frames.prefetch(on: BackgroundWork()).value
        await frames.saveForQuit(["tab_shown": (try Self.picture(), 2), "../escape": (try Self.picture(), 2)])
        #expect(Self.names(in: folder) == ["tab_shown@2x.jpg"], "written and awaited; an unsafe key never becomes a path")
        frames.save(try Self.picture(), for: "tab_late", scale: 2)
        frames.remove("tab_shown")
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.names(in: folder) == ["tab_shown@2x.jpg"], "the quit's tabs close and reopen next launch: their pictures stay")
    }

    @Test func noFolderKeepsNothing() async throws {
        let frames = BrowserPageFrames(directory: nil)
        await frames.prefetch(on: BackgroundWork()).value
        frames.save(try Self.picture(), for: "tab_a")
        #expect(frames.take("tab_a") == nil)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
