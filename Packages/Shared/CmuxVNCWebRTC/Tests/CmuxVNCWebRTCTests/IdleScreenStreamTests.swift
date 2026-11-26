#if os(macOS)
@testable import CmuxVNCWebRTC
import CoreVideo
import Foundation
import Testing
import WebRTC

/// RFD 0088 slice 3b, nothing on an idle screen: the host repeats a still
/// picture a few times for the encoder, then sends no video until the
/// picture changes or something asks for it again.
struct IdleRefreshTests {
    typealias Policy = ScreenStreamHost.IdleRefresh
    static let period = Policy.periodNs

    @Test func aNewPictureIsRepeatedABoundedNumberOfTimesThenNothing() {
        var policy = Policy()
        policy.pushed(now: 0, fresh: true)
        var now: UInt64 = 0
        var repeats = 0
        for _ in 0 ..< 40 {
            now += Self.period
            if policy.repeatNow(now: now) {
                repeats += 1
                policy.pushed(now: now, fresh: false)
            }
        }
        #expect(repeats == Policy.repeats)
        #expect(policy.isIdle(now: now + Self.period))
    }

    @Test func noRepeatWhileThePictureIsFresh() {
        var policy = Policy()
        policy.pushed(now: 1_000, fresh: true)
        #expect(!policy.repeatNow(now: 1_000 + Self.period / 2))
        #expect(!policy.isIdle(now: 1_000 + Self.period * 10), "repeats are still owed")
    }

    @Test func armingOnAStillScreenRepeatsAgain() {
        var policy = Policy()
        policy.pushed(now: 0, fresh: true)
        var now: UInt64 = 0
        while !policy.isIdle(now: now) {
            now += Self.period
            if policy.repeatNow(now: now) { policy.pushed(now: now, fresh: false) }
        }
        #expect(!policy.repeatNow(now: now + Self.period))
        policy.arm() // a keyframe request, a quality change, the viewer's refresh
        #expect(policy.repeatNow(now: now + Self.period))
        #expect(policy.remaining == Policy.repeats - 1)
    }

    @Test func nothingToRepeatBeforeTheFirstPicture() {
        var policy = Policy()
        #expect(!policy.repeatNow(now: Self.period * 3))
    }
}

/// End to end in one process, the host's real path to a viewer: a still
/// screen stops sending video, the viewer's refresh brings a picture, and a
/// small changing region costs what it changes. Prints IDLE-SCREEN lines.
@Suite(.serialized)
struct IdleScreenStreamTests {
    @Test(.timeLimit(.minutes(1))) func aStillScreenSendsNoVideo() async throws {
        let (hostSide, viewerSide) = LoopbackSignaling.pair()
        let source = StillScreen(width: 1280, height: 800, changingFps: 0)
        let host = ScreenStreamHost(name: "Mac", backend: { source }, log: { print("host: \($0)") })
        let hostTask = Task { try? await host.serve(hostSide) }
        defer { hostTask.cancel() }
        let counter = ScreenStreamTests.FrameCounter()
        let viewer = ScreenStreamViewer(signaling: viewerSide)
        viewer.onVideo = { $0.track.add(counter) }
        try await viewer.connect()
        defer {
            viewer.close()
            host.disconnectViewer()
        }
        // task-owner: bounded wait for the first picture
        for _ in 0 ..< 100 where counter.snapshot.0 == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.snapshot.0 > 0, "no picture arrived")

        // The repeats end after Policy.repeats periods (2 s); then a 4 s still window.
        try await Task.sleep(for: .seconds(3)) // repeats settle
        let before = await viewer.videoStats()
        try await Task.sleep(for: .seconds(4)) // still window
        let after = await viewer.videoStats()
        let frames = Int(after.framesReceived - before.framesReceived)
        let bytes = Int(after.bytesReceived - before.bytesReceived)
        print("IDLE-SCREEN still 1280x800 window=4s frames=\(frames) bytes=\(bytes) kbit/s=\(String(format: "%.1f", Double(bytes) * 8 / 4 / 1000))")
        #expect(frames == 0, "a still screen sent \(frames) frames in 4 s")

        // The viewer's refresh brings the picture back.
        viewer.send(ScreenInput(t: ScreenStreamViewer.refreshMessage))
        try await Task.sleep(for: .seconds(1)) // one repeat period and the round trip
        let refreshed = await viewer.videoStats()
        #expect(refreshed.framesReceived > after.framesReceived, "the viewer's refresh sent no picture")
    }

    @Test(.timeLimit(.minutes(1))) func aSmallChangingRegionCostsLittle() async throws {
        let (hostSide, viewerSide) = LoopbackSignaling.pair()
        let source = StillScreen(width: 1280, height: 800, changingFps: 10)
        let host = ScreenStreamHost(name: "Mac", backend: { source }, log: { print("host: \($0)") })
        let hostTask = Task { try? await host.serve(hostSide) }
        defer { hostTask.cancel() }
        let counter = ScreenStreamTests.FrameCounter()
        let viewer = ScreenStreamViewer(signaling: viewerSide)
        viewer.onVideo = { $0.track.add(counter) }
        try await viewer.connect()
        defer {
            viewer.close()
            host.disconnectViewer()
        }
        // task-owner: bounded wait for the first picture
        for _ in 0 ..< 100 where counter.snapshot.0 == 0 { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .seconds(3)) // the first keyframe and ramp-up
        let before = await viewer.videoStats()
        try await Task.sleep(for: .seconds(4)) // measurement window
        let after = await viewer.videoStats()
        let frames = Int(after.framesReceived - before.framesReceived)
        let kbps = (after.bytesReceived - before.bytesReceived) * 8 / 4 / 1000
        print("IDLE-SCREEN typing 1280x800 region=240x24@10fps window=4s frames=\(frames) kbit/s=\(String(format: "%.1f", kbps)) codec=\(after.codec ?? "?")")
        #expect(frames >= 20, "the changing region reached the viewer at \(frames / 4) fps")
    }
}

/// A grey desktop with a text-like block; with `changingFps` above 0, a
/// 240×24 region (a line being typed) changes that often and nothing else.
final class StillScreen: ScreenBackend, @unchecked Sendable {
    // @unchecked: the timer and `index` are touched only on `queue`.
    let width: Int
    let height: Int
    let changingFps: Int
    private let queue = DispatchQueue(label: "still-screen")
    private var timer: (any DispatchSourceTimer)?
    private var pool: CVPixelBufferPool?
    private var index = 0

    init(width: Int, height: Int, changingFps: Int) {
        self.width = width
        self.height = height
        self.changingFps = changingFps
    }

    var maximumFrameRate: Int? { 60 }

    func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void, displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        pool = created
        displays([CGSize(width: width, height: height)], 0)
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        // As ScreenCaptureKit: one picture at start, then one per change.
        queue.sync { if let buffer = next() { frame(buffer, full) } }
        guard changingFps > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / changingFps))
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = next() else { return }
            frame(buffer, full)
        }
        self.timer = timer
        timer.resume()
    }

    /// The desktop with the typed line's next state.
    private func next() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        index += 1
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for y in 0 ..< height {
                let row = luma + y * stride
                memset(row, 200, width)
                // Static text-like rows on the left half.
                if y % 24 >= 6, y % 24 < 18 {
                    for x in Swift.stride(from: 16, to: width / 2, by: 11) { memset(row + x, 40, 7) }
                }
                // The typed line: glyphs appear one by one, then it clears.
                if y >= height / 2, y < height / 2 + 24, y % 24 >= 6, y % 24 < 18 {
                    let glyphs = index % 24
                    for glyph in 0 ..< glyphs { memset(row + width / 2 + glyph * 10, 30, 7) }
                }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
        return buffer
    }

    func select(display index: Int) {}
    func handle(_ input: ScreenInput) {}
    func setFrameRate(_ fps: Int) {}

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }
}
#endif
