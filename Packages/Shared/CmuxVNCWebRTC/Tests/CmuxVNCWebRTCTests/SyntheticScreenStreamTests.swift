#if os(macOS)
import AppKit
import AVFoundation
@testable import CmuxVNCWebRTC
import CoreVideo
import Darwin
import Testing

/// Real WebRTC host/encoder/ICE/decoder and the Mac renderer, without capture permission,
/// a phone, an Internet signaling service, or Rust policy overrides.
@Suite(.serialized)
struct SyntheticScreenStreamTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func syntheticFramesReachTheDisplayedPixels() async throws {
        guard #available(macOS 14.4, *) else {
            Issue.record("displayedPixelBuffer requires macOS 14.4 or later")
            return
        }
        let wallStart = ContinuousClock.now
        let cpuStart = clock()
        let source = MarkerScreen()
        let (hostSide, viewerSide) = LoopbackSignaling.pair()
        let host = ScreenStreamHost(name: "synthetic-screen", backend: { source })
        let hostTask = Task { try await host.serve(hostSide) }
        let viewer = ScreenStreamViewer(signaling: viewerSide)
        let counter = ScreenStreamTests.FrameCounter()
        let video = ScreenVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let window = NSWindow(contentRect: video.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = video
        window.orderBack(nil)
        video.layoutSubtreeIfNeeded()
        let layer = try #require(video.layer?.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        viewer.onVideo = { box in
            box.track.add(counter)
            Task { @MainActor in video.attach(box) }
        }
        defer {
            video.detach()
            viewer.close()
            host.disconnectViewer()
            hostSide.close()
            viewerSide.close()
            hostTask.cancel()
            source.stop()
            window.close()
        }
        try await viewer.connect()
        // A distinct initial picture establishes the connection before measuring frame latency.
        try await waitForPixel(32, renderer: layer.sampleBufferRenderer, timeout: .seconds(10))
        let decodedBefore = counter.snapshot.0
        var latencies: [Double] = []
        for index in 0 ..< 12 {
            let shade: UInt8 = index.isMultiple(of: 2) ? 192 : 64
            let started = ContinuousClock.now
            source.set(shade)
            // Checking changed pixels catches a decoder callback that never reaches the display.
            try await waitForPixel(shade, renderer: layer.sampleBufferRenderer, timeout: .seconds(2))
            latencies.append(milliseconds(started.duration(to: .now)))
        }
        let stats = await viewer.videoStats()
        let decoded = counter.snapshot.0 - decodedBefore
        let sorted = latencies.sorted()
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        #expect(decoded >= 12)
        #expect(stats.framesDecoded >= 12)
        #expect(stats.framesReceived >= 12)
        #expect(stats.bytesReceived > 0)
        #expect(counter.snapshot.1 == CGSize(width: 320, height: 240))
        #expect(p95 < 250, "source change to displayed pixels p95 exceeded 250 ms")
        #expect(layer.sampleBufferRenderer.status != .failed)
        print("SCREEN_WEBRTC_SYNTHETIC presented=\(latencies.count) decoded=\(decoded) received=\(stats.framesReceived) p95_ms=\(p95) wall_ms=\(milliseconds(wallStart.duration(to: .now))) cpu_s=\(Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC))")
    }

    @available(macOS 14.4, *)
    @MainActor
    private func waitForPixel(_ shade: UInt8, renderer: AVSampleBufferVideoRenderer, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let pixel = renderer.displayedPixelBuffer(), Self.centerLuma(pixel).map({ abs($0 - Int(shade)) <= 8 }) == true { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PixelTimeout(shade: shade)
    }

    private struct PixelTimeout: Error { let shade: UInt8 }

    private static func centerLuma(_ pixel: CVPixelBuffer) -> Int? {
        guard CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) else { return nil }
        let offset = CVPixelBufferGetHeightOfPlane(pixel, 0) / 2 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + CVPixelBufferGetWidthOfPlane(pixel, 0) / 2
        return Int(base.load(fromByteOffset: offset, as: UInt8.self))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// The queue owns every mutable field, including the callback and timer.
private final class MarkerScreen: ScreenBackend, @unchecked Sendable {
    private let queue = DispatchQueue(label: "synthetic-webrtc-screen")
    private var timer: (any DispatchSourceTimer)?
    private var shade: UInt8 = 32
    var maximumFrameRate: Int? { 30 }

    func set(_ shade: UInt8) { queue.sync { self.shade = shade } }

    func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void, displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {
        displays([CGSize(width: 320, height: 240)], 0)
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                var pixel: CVPixelBuffer?
                let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
                guard CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixel) == kCVReturnSuccess, let pixel else { return }
                CVPixelBufferLockBaseAddress(pixel, [])
                if let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) {
                    memset(y, Int32(shade), CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * CVPixelBufferGetHeightOfPlane(pixel, 0))
                }
                if let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1) {
                    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) * CVPixelBufferGetHeightOfPlane(pixel, 1))
                }
                CVPixelBufferUnlockBaseAddress(pixel, [])
                frame(pixel, CGRect(x: 0, y: 0, width: 320, height: 240))
            }
            self.timer = timer
            timer.resume()
        }
    }
    func select(display index: Int) {}
    func handle(_ input: ScreenInput) {}
    func setFrameRate(_ fps: Int) {}
    func stop() { queue.sync { timer?.cancel(); timer = nil } }
}
#endif
