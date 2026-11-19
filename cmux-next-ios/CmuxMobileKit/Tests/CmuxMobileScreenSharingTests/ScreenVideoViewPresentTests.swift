#if os(iOS)
import AVFoundation
import CmuxVNCWebRTC
import CoreVideo
import Foundation
import MetalKit
import Testing
import UIKit
import WebRTC

/// How a Mac's streamed screen reaches the iPhone's display. The view used to be
/// libwebrtc's `RTCMTLVideoView`: an `MTKView` that redraws the newest frame on its
/// own main-thread timer, at most 60 times a second. A 120 fps stream from a
/// ProMotion Mac then showed at most 60 fps, each frame waited for the next tick,
/// and main-thread work held frames back. `ScreenVideoView` now hands each decoded
/// frame to an `AVSampleBufferDisplayLayer` from libwebrtc's own thread.
///
/// These run unhosted (no app, nothing composited), so they check what holds
/// without a window and print the numbers:
///   SCREEN-VIDEO-PRESENT metal-view fps=... paused=... on-demand=...
///   SCREEN-VIDEO-PRESENT sink frames=... rendering-while-main-blocked=... enqueue_p50_us=... enqueue_p95_us=...
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ScreenVideoViewPresentTests {
    /// libwebrtc's Metal view, as this app's viewer used it before: its MTKView
    /// runs its own redraw timer (not paused, not on demand) at 60 frames a second.
    @Test func libwebrtcsMetalViewRedrawsOnItsOwnSixtyHertzTimer() throws {
        let view = RTCMTLVideoView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let metal = try #require(Self.metalView(in: view), "RTCMTLVideoView holds an MTKView")
        print("SCREEN-VIDEO-PRESENT metal-view fps=\(metal.preferredFramesPerSecond) paused=\(metal.isPaused) on-demand=\(metal.enableSetNeedsDisplay)")
        #expect(metal.preferredFramesPerSecond == 60, "the redraw timer's rate caps what a 120 fps stream shows")
        #expect(!metal.isPaused && !metal.enableSetNeedsDisplay, "frames are sampled by the view's timer, not drawn when they arrive")
    }

    /// The stream's view: a display layer that frames reach from libwebrtc's thread.
    /// 120 frames go in from a background thread at 120 fps while the main thread is
    /// blocked; the layer's renderer is already rendering before the main thread is
    /// free, and each hand-off costs well under a millisecond.
    @Test func framesReachTheDisplayLayerWhileTheMainThreadIsBlocked() async throws {
        let view = ScreenVideoView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let layer = try #require(view.layer as? AVSampleBufferDisplayLayer, "the view is backed by a display layer")
        let renderer = layer.sampleBufferRenderer
        let factory = RTCPeerConnectionFactory()
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "screen")
        view.attach(VideoTrackBox(track: track))
        #expect(renderer.status == .unknown, "nothing enqueued yet")

        let feeder = Feeder(source: source, renderer: renderer)
        // The main thread is busy (a SwiftUI pass, a gesture) for the whole feed.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            feeder.feed(frames: 120, fps: 120)
            done.signal()
        }
        let blockedUntil = Date().addingTimeInterval(1.5)
        while done.wait(timeout: .now()) == .timedOut, Date() < blockedUntil {} // main thread blocked on purpose
        let result = feeder.result
        print("SCREEN-VIDEO-PRESENT sink frames=\(result.frames) rendering-while-main-blocked=\(result.renderingWhileFeeding) enqueue_p50_us=\(result.p50Us) enqueue_p95_us=\(result.p95Us)")
        #expect(result.frames == 120)
        #expect(result.renderingWhileFeeding, "the layer took frames with the main thread blocked")
        #expect(result.p95Us < 1000, "a frame's hand-off to the layer takes \(result.p95Us) µs at p95")
    }

    private static func metalView(in view: UIView) -> MTKView? {
        for sub in view.subviews {
            if let metal = sub as? MTKView { return metal }
            if let found = metalView(in: sub) { return found }
        }
        return nil
    }
}

/// Pushes NV12 frames into a WebRTC video source (libwebrtc delivers each to the
/// track's renderers on this thread) and times each push.
private final class Feeder: @unchecked Sendable {
    // @unchecked: used from one background thread, then read after it signals.
    struct Result {
        var frames = 0
        var renderingWhileFeeding = false
        var p50Us = 0
        var p95Us = 0
    }

    private let source: RTCVideoSource
    private let renderer: AVSampleBufferVideoRenderer
    private(set) var result = Result()

    init(source: RTCVideoSource, renderer: AVSampleBufferVideoRenderer) {
        self.source = source
        self.renderer = renderer
    }

    func feed(frames: Int, fps: Int) {
        let capturer = RTCVideoCapturer(delegate: source)
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 832,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard let pool else { return }
        var costs: [UInt64] = []
        let interval = 1_000_000_000 / UInt64(fps)
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0 ..< frames {
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                memset(luma, Int32(16 + index % 200), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let at = start + UInt64(index) * interval
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(at))
            let before = DispatchTime.now().uptimeNanoseconds
            source.capturer(capturer, didCapture: frame)
            costs.append(DispatchTime.now().uptimeNanoseconds - before)
            result.frames += 1
            let next = at + interval
            let now = DispatchTime.now().uptimeNanoseconds
            if next > now { usleep(useconds_t((next - now) / 1000)) } // paces the synthetic 120 fps source
        }
        result.renderingWhileFeeding = renderer.status == .rendering
        let sorted = costs.sorted()
        if !sorted.isEmpty {
            result.p50Us = Int(sorted[sorted.count / 2] / 1000)
            result.p95Us = Int(sorted[min(sorted.count - 1, sorted.count * 95 / 100)] / 1000)
        }
    }
}
#endif
