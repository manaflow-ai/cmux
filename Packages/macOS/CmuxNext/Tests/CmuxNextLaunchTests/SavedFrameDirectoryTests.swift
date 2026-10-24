import CmuxNextCompat
@testable import CmuxNextLaunch
import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// #17587: the panes' last frames (terminals', agent pages') are listed and decoded by one reader
/// begun at the top of `main`, and handed to the pane builds without ever blocking the main thread:
/// a decoded frame is taken at once, one not decoded yet goes to its pane when it is. Before, each
/// pane build read and decoded its JPEG or PNG on the main thread, and then waited on a decode lane
/// (`lanes[lane].sync {}`) for a frame being decoded.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SavedFrameDirectoryTests {
    /// An 8x6 pixel PNG.
    nonisolated static func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A directory saved with a PNG for each of `keys` at 2x.
    nonisolated static func saved(_ keys: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "saved-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        let png = try png()
        SavedFrameDirectory.write(Dictionary(uniqueKeysWithValues: keys.map { (SavedFrameDirectory.fileName($0, scale: 2, ext: "png"), png) }), to: url)
        return url
    }

    /// A decode the test holds: each decode of a key in `held` waits until the test lets it go, and
    /// every decode is recorded in order. A test gate on the reader's own queue, not a lock on state.
    nonisolated final class HeldDecoder: Sendable {
        let held: Set<String>
        private let gates: [String: DispatchSemaphore]
        private let order = Mutex<[String]>([])
        private let started: AsyncStream<String>.Continuation
        let starts: AsyncStream<String>

        init(holding held: Set<String>) {
            self.held = held
            gates = Dictionary(uniqueKeysWithValues: held.map { ($0, DispatchSemaphore(value: 0)) })
            let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(16))
            starts = stream
            started = continuation
        }

        var decoded: [String] { order.withLock { $0 } }

        func release(_ key: String) { gates[key]?.signal() }

        func decode(_ file: URL, scale: Int) -> SavedFrame? {
            let key = String(file.lastPathComponent.prefix { $0 != "@" })
            started.yield(key)
            gates[key]?.wait()
            order.withLock { $0.append(key) }
            guard let data = try? Data(contentsOf: file), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return SavedFrame(image: image, scale: scale)
        }
    }

    /// Waits for the decode of `key` to begin.
    static func decodeStarts(_ key: String, in decoder: HeldDecoder) async {
        for await started in decoder.starts where started == key { return }
    }

    @Test func aDecodedFrameIsTakenAtOnceAndHandedOutOnce() async throws {
        let url = try Self.saved(["tab_a"])
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames")
        await frames.readerIdle()
        let frame = try #require(frames.take("tab_a") { _ in Issue.record("a decoded frame is not delivered later") })
        #expect(frame.scale == 2)
        #expect(frame.size == CGSize(width: 4, height: 3))
        let again = frames.take("tab_a") { _ in Issue.record("handed out twice") }
        #expect(again.isNil, "a frame is handed out once per launch")
    }

    /// The pane build asks while the reader still decodes its frame: the take returns at once (the
    /// decode is held, so a take that waited for it would never return), and the frame reaches
    /// the pane on the main actor when its decode ends.
    @Test func aFrameNotDecodedYetIsDeliveredLaterWithoutBlockingTheTake() async throws {
        let url = try Self.saved(["tab_a"])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = HeldDecoder(holding: ["tab_a"])
        let frames = SavedFrameDirectory(url: url, name: "test_frames", decode: { decoder.decode($0, scale: $1) })
        await Self.decodeStarts("tab_a", in: decoder)
        let (delivered, deliver) = AsyncStream<SavedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let now = frames.take("tab_a") { frame in
            #expect(Thread.isMainThread, "the frame reaches its pane on the main actor")
            deliver.yield(frame)
        }
        #expect(now.isNil, "the take did not wait for the decode")
        decoder.release("tab_a")
        var got: SavedFrame?
        for await frame in delivered {
            got = frame
            break
        }
        #expect(got?.scale == 2)
        let again = frames.take("tab_a") { _ in Issue.record("handed out twice") }
        #expect(again.isNil)
    }

    /// The frame a pane asks for is decoded next, before frames no pane asked for; then the first
    /// windows' frames (`prioritize`), then the rest.
    @Test func askedFramesDecodeFirstThenTheShownOnesThenTheRest() async throws {
        let url = try Self.saved(["tab_a", "tab_b", "tab_c", "tab_d"])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = HeldDecoder(holding: ["tab_a"])
        let frames = SavedFrameDirectory(url: url, name: "test_frames", decode: { decoder.decode($0, scale: $1) })
        await Self.decodeStarts("tab_a", in: decoder)
        frames.prioritize(["tab_c"])
        let asked = frames.take("tab_d") { _ in }
        #expect(asked.isNil)
        decoder.release("tab_a")
        await frames.readerIdle()
        #expect(decoder.decoded == ["tab_a", "tab_d", "tab_c", "tab_b"])
    }

    @Test func aKeyWithNoFileOrNoSafeNameGetsNothing() async throws {
        let url = try Self.saved(["tab_a"])
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames")
        await frames.readerIdle()
        let missing = frames.take("tab_b") { _ in Issue.record("no such file") }
        let unsafe = frames.take("../tab_a") { _ in Issue.record("not a file name") }
        #expect(missing.isNil)
        #expect(unsafe.isNil, "a key that is not a file name never becomes a path")
    }

    /// A take before the listing ended waits for the listing (as a waiter, not on the thread):
    /// a key with a file then gets its frame, one without is dropped.
    @Test func aTakeBeforeTheListingGetsItsFrameOnceListed() async throws {
        let url = try Self.saved(["tab_a"])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = HeldDecoder(holding: ["tab_a"])
        let frames = SavedFrameDirectory(url: url, name: "test_frames", decode: { decoder.decode($0, scale: $1) })
        let (delivered, deliver) = AsyncStream<SavedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        _ = frames.take("tab_a") { deliver.yield($0) }
        _ = frames.take("tab_z") { _ in Issue.record("no such file") }
        decoder.release("tab_a")
        for await frame in delivered {
            #expect(frame.scale == 2)
            break
        }
        await frames.readerIdle()
    }

    @Test func releaseDropsTheFramesAndThePanesStillWaiting() async throws {
        let url = try Self.saved(["tab_a", "tab_b"])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = HeldDecoder(holding: ["tab_a"])
        let frames = SavedFrameDirectory(url: url, name: "test_frames", decode: { decoder.decode($0, scale: $1) })
        await Self.decodeStarts("tab_a", in: decoder)
        let waiting = frames.take("tab_a") { _ in Issue.record("a released frame is not delivered") }
        #expect(waiting.isNil)
        frames.release()
        decoder.release("tab_a")
        await frames.readerIdle()
        #expect(decoder.decoded == ["tab_a"], "the reader starts no decode after the release")
        let released = frames.take("tab_b") { _ in Issue.record("released") }
        #expect(released.isNil)
        // A delivery would be a main-actor task enqueued before this one: let it run, then check none came.
        await Task.yield()
    }

    /// A listed frame whose decode failed is not read again: its taker gets nothing at once.
    @Test func aListedFrameThatFailedToDecodeIsNotReadAgain() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "saved-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        SavedFrameDirectory.write([SavedFrameDirectory.fileName("tab_a", scale: 2, ext: "png"): Data("not an image".utf8)], to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = SavedFrameDirectory(url: url, maximumBytes: 1 << 20, name: "test_frames")
        await frames.readerIdle()
        let failed = frames.take("tab_a") { _ in Issue.record("a failed decode is not delivered") }
        #expect(failed.isNil)
    }

    @Test func noDirectoryKeepsNothing() async {
        let frames = SavedFrameDirectory(url: nil, maximumBytes: 1 << 20, name: "test_frames")
        await frames.readerIdle()
        let none = frames.take("tab_a") { _ in Issue.record("no directory") }
        #expect(none.isNil)
    }
}

private extension Optional {
    /// Whether there is no value (`SavedFrame` is not `Equatable`, so `#expect(frame == nil)` has no `==`).
    var isNil: Bool { self == nil }
}
