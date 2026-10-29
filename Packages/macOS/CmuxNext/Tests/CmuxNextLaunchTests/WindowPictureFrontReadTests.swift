import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

/// The launch's read of the front window's picture, of the files the quit writes
/// (`WindowPictureStore.write`, p08-startup-057: `<profile>/<window>.heic|json`): read and decoded off the main
/// thread, only the front window's in its profile's folder, nothing at all when no picture was saved, handed to
/// the first frame once and never waited for, and dropped at startup complete when nobody took it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WindowPictureFrontReadTests {
    static let work = BackgroundWork(label: "test.window-pictures")
    nonisolated static let front = "0b5c7d3e-6f1a-4b2c-9d8e-1f2a3b4c5d6e"
    nonisolated static let back = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    nonisolated static let defaultProfile = "default"
    nonisolated static let workProfile = "prof_0123456789abcdef0123456789abcdef"
    static let allowed = WindowPictureStore.Eligibility(incognito: false, onScreen: true, onActiveSpace: true, fullScreen: false,
                                                        hiddenFromCapture: false)
    /// PNG: the reader decodes any ImageIO format, and the test machine needs no HEIC encoder.
    static let png: @Sendable (CGImage) -> Data? = { blockingImageEncode($0, type: UTType.png.identifier as CFString) }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "window-pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func meta(window: String, profile: String) -> WindowPictureMeta {
        WindowPictureMeta(window: window, profile: profile, frame: CGRect(x: 100, y: 200, width: 8, height: 6), screen: "DISPLAY-1",
                          scale: 1, appearance: "NSAppearanceNameDarkAqua", theme: WindowPictureMeta.fingerprint(["theme"]),
                          sidebarWidth: 0, build: "1.0 (1)",
                          layout: WindowPictureMeta.Layout(workspaces: ["ws_a"], shown: "ws_a",
                                                           screens: [.init(id: "scr_1", tree: .leaf("1"), zoomed: nil)]),
                          regions: [.init(kind: .pane, id: "tab_a", frame: CGRect(x: 0, y: 0, width: 8, height: 6))])
    }

    /// An opaque gray 8x6 window.
    static func shot(window: String, profile: String) throws -> WindowPictureStore.Shot {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return WindowPictureStore.Shot(eligibility: allowed, base: try #require(context.makeImage()), size: CGSize(width: 8, height: 6),
                                       layers: [], fills: [], background: .init(red: 0, green: 0, blue: 0),
                                       meta: meta(window: window, profile: profile))
    }

    /// Saves `windows`' pictures as the quit does (057's `save`: per profile, meta last, on the files lane).
    static func save(_ windows: [(window: String, profile: String)], in directory: URL) async throws {
        let shots = try windows.map { try shot(window: $0.window, profile: $0.profile) }
        await WindowPictureStore(directory: directory, work: work, encode: png).save(shots)
        for window in windows {
            let folder = directory.appending(path: window.profile)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "\(window.window).json").path), "the quit wrote no meta")
        }
    }

    nonisolated static func frontWindow(_ window: String = front, profile: String = defaultProfile) -> WindowPictureStore.FrontWindow {
        WindowPictureStore.FrontWindow(window: window, profile: profile)
    }

    @Test func theFrontWindowsPictureIsReadAndDecodedOffMainAndHandedOutOnce() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.save([(Self.front, Self.defaultProfile), (Self.back, Self.workProfile)], in: directory)
        let reads = Reads()
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        var names = marks.makeAsyncIterator()
        let pictures = WindowPictureStore(directory: directory, work: Self.work, reader: reads.reader)
        pictures.prefetchFront({ Self.frontWindow() }, mark: { mark.yield($0) })
        let finished = await pictures.finishedFront()
        let decoded = await names.next()
        #expect(decoded == "launch_picture_decoded")
        #expect(finished?.windowID == Self.front)
        #expect(reads.all.map(\.path) == ["\(Self.defaultProfile)/\(Self.front).json", "\(Self.defaultProfile)/\(Self.front).heic"],
                "the launch read more than the front window's meta and picture")
        #expect(reads.all.allSatisfy { !$0.onMain }, "the launch read the picture on the main thread")
        let picture = try #require(pictures.takeFront())
        #expect(picture.image.width == 8 && picture.image.height == 6)
        #expect(picture.meta == Self.meta(window: Self.front, profile: Self.defaultProfile))
        #expect(pictures.takeFront() == nil, "the picture was handed out twice")
    }

    /// A window that shows another profile is read from that profile's folder.
    @Test func theFrontWindowsProfileNamesItsFolder() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.save([(Self.back, Self.workProfile)], in: directory)
        let pictures = WindowPictureStore(directory: directory, work: Self.work)
        pictures.prefetchFront({ Self.frontWindow(Self.back, profile: Self.workProfile) })
        #expect(await pictures.finishedFront()?.windowID == Self.back, "the picture in the window's profile folder was not read")
        let otherProfile = WindowPictureStore(directory: directory, work: Self.work)
        otherProfile.prefetchFront({ Self.frontWindow(Self.back) })
        #expect(await otherProfile.finishedFront() == nil, "a picture saved for another profile was shown")
    }

    /// No picture saved: the snapshot is not asked and no file is read. No front window, a front window with no
    /// picture, or an id that is not a plain slug: no file is read.
    @Test func noPictureNoRead() async throws {
        let empty = Self.folder()
        defer { try? FileManager.default.removeItem(at: empty) }
        try FileManager.default.createDirectory(at: empty.appending(path: Self.defaultProfile), withIntermediateDirectories: true)
        let reads = Reads(), asks = Asks()
        let none = WindowPictureStore(directory: empty, work: Self.work, reader: reads.reader)
        none.prefetchFront({ asks.ask(Self.frontWindow()) })
        #expect(await none.finishedFront() == nil)
        #expect(asks.count == 0, "the launch read the snapshot with no picture saved")
        #expect(reads.all.isEmpty, "the launch read a file with no picture saved")

        let saved = Self.folder()
        defer { try? FileManager.default.removeItem(at: saved) }
        try await Self.save([(Self.back, Self.defaultProfile)], in: saved)
        let noFront = WindowPictureStore(directory: saved, work: Self.work, reader: reads.reader)
        noFront.prefetchFront({ asks.ask(nil) })
        #expect(await noFront.finishedFront() == nil)
        let otherFront = WindowPictureStore(directory: saved, work: Self.work, reader: reads.reader)
        otherFront.prefetchFront({ asks.ask(Self.frontWindow()) })
        #expect(await otherFront.finishedFront() == nil, "a window behind the front one gave the first frame its picture")
        #expect(asks.count == 2)
        #expect(reads.all.isEmpty, "the launch read a picture of a window that is not front")

        for unsafe in [Self.frontWindow("../\(Self.back)"), Self.frontWindow(Self.back, profile: "../\(Self.defaultProfile)")] {
            let store = WindowPictureStore(directory: saved, work: Self.work, reader: reads.reader)
            store.prefetchFront({ unsafe })
            #expect(await store.finishedFront() == nil)
        }
        #expect(reads.all.isEmpty, "a window or profile id became a path outside the folder")

        let noFolder = WindowPictureStore(directory: nil, work: Self.work, reader: reads.reader)
        noFolder.prefetchFront({ asks.ask(Self.frontWindow()) })
        #expect(await noFolder.finishedFront() == nil)
        #expect(asks.count == 2)
    }

    /// A meta that names another window than its file (a hand-copied or stale file) shows nothing, and its
    /// picture is not decoded.
    @Test func aMetaOfAnotherWindowIsNotShown() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.save([(Self.back, Self.defaultProfile)], in: directory)
        let folder = directory.appending(path: Self.defaultProfile)
        for ext in ["json", "heic"] {
            try FileManager.default.copyItem(at: folder.appending(path: "\(Self.back).\(ext)"), to: folder.appending(path: "\(Self.front).\(ext)"))
        }
        let reads = Reads()
        let pictures = WindowPictureStore(directory: directory, work: Self.work, reader: reads.reader)
        pictures.prefetchFront({ Self.frontWindow() })
        #expect(await pictures.finishedFront() == nil, "a picture of another window was shown")
        #expect(reads.all.map(\.path) == ["\(Self.defaultProfile)/\(Self.front).json"], "the launch decoded a picture its meta refused")
    }

    /// The first frame never waits: before the read ends it gets nothing; after, the picture.
    @Test func theFirstFrameBeforeTheReadEndsGetsNoneAndNeverWaits() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.save([(Self.front, Self.defaultProfile)], in: directory)
        let gate = DispatchSemaphore(value: 0)
        let reader = LaunchFileReader { url, maximumBytes in
            gate.wait()
            guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
            return data
        }
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        var names = marks.makeAsyncIterator()
        let pictures = WindowPictureStore(directory: directory, work: Self.work, reader: reader)
        pictures.prefetchFront({ Self.frontWindow() }, mark: { mark.yield($0) })
        #expect(pictures.takeFront() == nil, "the first frame got a picture before the read ended")
        let missed = await names.next()
        #expect(missed == "launch_picture_missed")
        gate.signal() // the meta
        gate.signal() // the picture
        _ = await pictures.frontFinished()
        let decoded = await names.next()
        #expect(decoded == "launch_picture_decoded")
        #expect(pictures.takeFront()?.windowID == Self.front, "the first frame after the read got no picture")
    }

    /// Startup complete drops an untaken picture (it is large); a taken one is not dropped again.
    @Test func anUntakenPictureGoesAtTheDrop() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.save([(Self.front, Self.defaultProfile)], in: directory)
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        var names = marks.makeAsyncIterator()
        let pictures = WindowPictureStore(directory: directory, work: Self.work)
        pictures.prefetchFront({ Self.frontWindow() }, mark: { mark.yield($0) })
        _ = await pictures.frontFinished()
        let decoded = await names.next()
        #expect(decoded == "launch_picture_decoded")
        pictures.dropFront()
        mark.finish()
        let dropped = await names.next()
        #expect(dropped == "launch_picture_dropped")
        #expect(pictures.takeFront() == nil, "a dropped picture was handed out")
        pictures.prefetchFront({ Self.frontWindow() })
        #expect(await pictures.finishedFront() == nil, "a dropped read started again")

        let taken = WindowPictureStore(directory: directory, work: Self.work)
        let (takenMarks, takenMark) = AsyncStream.makeStream(of: String.self)
        taken.prefetchFront({ Self.frontWindow() }, mark: { takenMark.yield($0) })
        _ = await taken.frontFinished()
        #expect(taken.takeFront() != nil)
        taken.dropFront()
        takenMark.finish()
        var seen: [String] = []
        for await name in takenMarks { seen.append(name) }
        #expect(seen == ["launch_picture_decoded"], "a taken picture was reported dropped")
    }
}

/// Records each file the reader is asked for (`<profile>/<file>`) and whether it ran on the main thread.
nonisolated private final class Reads: Sendable {
    private let state = Mutex<[(path: String, onMain: Bool)]>([])
    var all: [(path: String, onMain: Bool)] { state.withLock { $0 } }
    var reader: LaunchFileReader {
        LaunchFileReader { [self] url, maximumBytes in
            let path = "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
            state.withLock { $0.append((path, Thread.isMainThread)) }
            guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
            return data
        }
    }
}

/// Counts the times the launch asks which window is front (the snapshot read it stands for).
nonisolated private final class Asks: Sendable {
    private let state = Mutex(0)
    var count: Int { state.withLock { $0 } }
    func ask(_ window: WindowPictureStore.FrontWindow?) -> WindowPictureStore.FrontWindow? {
        state.withLock { $0 += 1 }
        return window
    }
}
