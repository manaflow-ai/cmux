import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextLaunch
import CmuxNextWakeups
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

/// The launch's read of the front window's picture (p08-startup-058): read and decoded off the main thread, only
/// the front window's, nothing at all when no picture was saved, handed to the first frame once and never waited
/// for, and dropped at startup complete when nobody took it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct WindowPictureFrontReadTests {
    static let work = BackgroundWork(label: "test.window-pictures")
    nonisolated static let front = "0b5c7d3e-6f1a-4b2c-9d8e-1f2a3b4c5d6e"
    nonisolated static let back = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "window-pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// An opaque gray 8x6 image as PNG bytes (the reader decodes any ImageIO format; the quit writes HEIC).
    static func pictureBytes() throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try #require(context.makeImage())
        return try #require(blockingImageEncode(image, type: UTType.png.identifier as CFString))
    }

    /// Saves `windows`' pictures and metas in `directory` as the quit does (meta last).
    static func save(_ windows: [String], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for window in windows {
            try pictureBytes().write(to: directory.appending(path: WindowPictureStore.pictureName(window)))
            try Data("{\"window\":\"\(window)\"}".utf8).write(to: directory.appending(path: WindowPictureStore.metaName(window)))
        }
    }

    @Test func theFrontWindowsPictureIsReadAndDecodedOffMainAndHandedOutOnce() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.save([Self.front, Self.back], in: directory)
        let reads = Reads()
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        var names = marks.makeAsyncIterator()
        let pictures = WindowPictureStore(directory: directory, work: Self.work, reader: reads.reader)
        pictures.prefetchFront({ Self.front }, mark: { mark.yield($0) })
        let finished = await pictures.frontFinished()
        let decoded = await names.next()
        #expect(decoded == "launch_picture_decoded")
        #expect(finished?.windowID == Self.front)
        #expect(reads.all.map(\.name) == [WindowPictureStore.metaName(Self.front), WindowPictureStore.pictureName(Self.front)],
                "the launch read more than the front window's meta and picture")
        #expect(reads.all.allSatisfy { !$0.onMain }, "the launch read the picture on the main thread")
        let picture = try #require(pictures.takeFront())
        #expect(picture.image.width == 8 && picture.image.height == 6)
        #expect(picture.meta == Data("{\"window\":\"\(Self.front)\"}".utf8))
        #expect(pictures.takeFront() == nil, "the picture was handed out twice")
    }

    /// No picture saved: the snapshot is not asked and no file is read. No front window, or a front window with no
    /// picture: no picture file is read.
    @Test func noPictureNoRead() async throws {
        let empty = Self.folder()
        defer { try? FileManager.default.removeItem(at: empty) }
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let reads = Reads(), asks = Asks()
        let none = WindowPictureStore(directory: empty, work: Self.work, reader: reads.reader)
        none.prefetchFront({ asks.ask(Self.front) })
        #expect(await none.frontFinished() == nil)
        #expect(asks.count == 0, "the launch read the snapshot with no picture saved")
        #expect(reads.all.isEmpty, "the launch read a file with no picture saved")

        let saved = Self.folder()
        defer { try? FileManager.default.removeItem(at: saved) }
        try Self.save([Self.back], in: saved)
        let noFront = WindowPictureStore(directory: saved, work: Self.work, reader: reads.reader)
        noFront.prefetchFront({ asks.ask(nil) })
        #expect(await noFront.frontFinished() == nil)
        let otherFront = WindowPictureStore(directory: saved, work: Self.work, reader: reads.reader)
        otherFront.prefetchFront({ asks.ask(Self.front) })
        #expect(await otherFront.frontFinished() == nil, "a window behind the front one gave the first frame its picture")
        #expect(asks.count == 2)
        #expect(reads.all.isEmpty, "the launch read a picture of a window that is not front")

        let unsafe = WindowPictureStore(directory: saved, work: Self.work, reader: reads.reader)
        unsafe.prefetchFront({ "../\(Self.back)" })
        #expect(await unsafe.frontFinished() == nil)
        #expect(reads.all.isEmpty, "a window id became a path outside the folder")

        let noFolder = WindowPictureStore(directory: nil, work: Self.work, reader: reads.reader)
        noFolder.prefetchFront({ asks.ask(Self.front) })
        #expect(await noFolder.frontFinished() == nil)
        #expect(asks.count == 2)
    }

    /// The first frame never waits: before the read ends it gets nothing; after, the picture.
    @Test func theFirstFrameBeforeTheReadEndsGetsNoneAndNeverWaits() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.save([Self.front], in: directory)
        let gate = DispatchSemaphore(value: 0)
        let reader = LaunchFileReader { url, maximumBytes in
            gate.wait()
            guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
            return data
        }
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        var names = marks.makeAsyncIterator()
        let pictures = WindowPictureStore(directory: directory, work: Self.work, reader: reader)
        pictures.prefetchFront({ Self.front }, mark: { mark.yield($0) })
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
        try Self.save([Self.front], in: directory)
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        var names = marks.makeAsyncIterator()
        let pictures = WindowPictureStore(directory: directory, work: Self.work)
        pictures.prefetchFront({ Self.front }, mark: { mark.yield($0) })
        _ = await pictures.frontFinished()
        let decoded = await names.next()
        #expect(decoded == "launch_picture_decoded")
        pictures.drop()
        mark.finish()
        let dropped = await names.next()
        #expect(dropped == "launch_picture_dropped")
        #expect(pictures.takeFront() == nil, "a dropped picture was handed out")
        pictures.prefetchFront({ Self.front })
        #expect(await pictures.frontFinished() == nil, "a dropped read started again")

        let taken = WindowPictureStore(directory: directory, work: Self.work)
        let (takenMarks, takenMark) = AsyncStream.makeStream(of: String.self)
        taken.prefetchFront({ Self.front }, mark: { takenMark.yield($0) })
        _ = await taken.frontFinished()
        #expect(taken.takeFront() != nil)
        taken.drop()
        takenMark.finish()
        var seen: [String] = []
        for await name in takenMarks { seen.append(name) }
        #expect(seen == ["launch_picture_decoded"], "a taken picture was reported dropped")
    }
}

/// Records each file the reader is asked for and whether it ran on the main thread.
nonisolated private final class Reads: Sendable {
    private let state = Mutex<[(name: String, onMain: Bool)]>([])
    var all: [(name: String, onMain: Bool)] { state.withLock { $0 } }
    var reader: LaunchFileReader {
        LaunchFileReader { [self] url, maximumBytes in
            state.withLock { $0.append((url.lastPathComponent, Thread.isMainThread)) }
            guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
            return data
        }
    }
}

/// Counts the times the launch asks which window is front (the snapshot read it stands for).
nonisolated private final class Asks: Sendable {
    private let state = Mutex(0)
    var count: Int { state.withLock { $0 } }
    func ask(_ window: String?) -> String? {
        state.withLock { $0 += 1 }
        return window
    }
}
