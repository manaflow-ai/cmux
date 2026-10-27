import AppKit
@testable import CmuxNextPhone
import CoreVideo
import IOSurface
import Testing

/// The live phone screen presents off main (p03-rendering-114): each SimulatorKit frame, on the tab's
/// frame queue, becomes a pixel buffer over the simulator's IOSurface and goes to remote view
/// presenter A, which draws and presents it on its render queue (`presentsWithTransaction = false`).
/// Only the first frame of a session and a new size take a main-thread turn. Chrome's GPU thread
/// presents the same way, with the UI thread out of a frame's path
/// (gpu/ipc/service/image_transport_surface_overlay_mac.h).
@MainActor @Suite(.serialized) struct PhoneLiveScreenOffMainTests {
    static let portrait = CGSize(width: 120, height: 260)
    static let landscape = CGSize(width: 260, height: 120)

    /// `count` frames of one simulator framebuffer of `size`, each a separate callback on `queue`
    /// as SimulatorKit makes them, at the simulator's 60 fps.
    nonisolated static func feed(_ frames: PhoneLiveFrames, size: CGSize, count: Int, on queue: DispatchQueue) {
        for index in 0..<count {
            queue.asyncAfter(deadline: .now() + .milliseconds(16 * index)) {
                guard let surface = Self.surface(size) else { return }
                _ = frames.frame(surface)
            }
        }
    }

    nonisolated static func surface(_ size: CGSize, format: OSType = kCVPixelFormatType_32BGRA) -> IOSurface? {
        IOSurface(properties: [.width: Int(size.width), .height: Int(size.height), .bytesPerElement: 4, .pixelFormat: format])
    }

    @Test(.timeLimit(.minutes(1))) func aFrameTakesNoMainTurnOnlyTheFirstAndASizeChangeDo() async throws {
        let queue = DispatchQueue(label: "test.phone.frames", qos: .userInteractive)
        let view = PhoneScreenView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let frames = view.startLive()

        Self.feed(frames, size: Self.portrait, count: 60, on: queue)
        try await Self.until("the portrait size reached the view") { view.mapping.screen == Self.portrait }
        Self.feed(frames, size: Self.landscape, count: 60, on: queue)
        try await Self.until("the landscape size reached the view") { view.mapping.screen == Self.landscape }
        // A size the view has: no main turn at all.
        Self.feed(frames, size: Self.landscape, count: 60, on: queue)
        try await Self.until("the frames went out") { await Self.drained(queue) }
        await Self.settle()

        #expect(view.liveMainTurns == 2, "main turns \(view.liveMainTurns) for 180 frames and 2 sizes")
        view.close()
    }

    /// The layer leaves the tree at once, and a frame SimulatorKit queued before it unregistered
    /// reaches nothing and takes no main turn.
    @Test(.timeLimit(.minutes(1))) func endingTheLiveScreenStopsLateFrames() async throws {
        let view = PhoneScreenView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let frames = view.startLive()
        let first = try #require(Self.surface(Self.portrait))
        #expect(frames.frame(first))
        try await Self.until("the first frame reached the view") { view.liveMainTurns == 1 }

        view.endLive()
        #expect(frames.presenter.layer.superlayer == nil)
        let late = try #require(Self.surface(Self.landscape))
        #expect(!frames.frame(late), "a frame after the end reached the presenter")
        await Self.settle()
        #expect(view.liveMainTurns == 1)
        #expect(view.mapping.screen == Self.portrait)

        // A new session reports its first frame again, the same size included.
        let again = view.startLive()
        #expect(again.frame(first))
        try await Self.until("the new session's first frame reached the view") { view.liveMainTurns == 2 }
        view.close()
    }

    @Test func theScreenStreamsOnlySurfacesPresenterADraws() throws {
        let bgra = try #require(Self.surface(Self.portrait))
        let tenBit = try #require(Self.surface(Self.portrait, format: kCVPixelFormatType_ARGB2101010LEPacked))
        let packedYUV = try #require(Self.surface(Self.portrait, format: kCVPixelFormatType_422YpCbCr8))
        #expect(PhoneLiveFrames.canDraw(bgra))
        #expect(PhoneLiveFrames.canDraw(tenBit))
        #expect(!PhoneLiveFrames.canDraw(packedYUV))
    }

    // MARK: Helpers

    /// True once every block queued on `queue` before it (and their delayed frames) ran.
    nonisolated static func drained(_ queue: DispatchQueue) async -> Bool {
        try? await Task.sleep(for: .milliseconds(16 * 60 + 50))
        return await withCheckedContinuation { done in queue.async { done.resume(returning: true) } }
    }

    /// Lets every main-actor job already posted run.
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
        for _ in 0..<20 { await Task.yield() }
    }

    static func until(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
