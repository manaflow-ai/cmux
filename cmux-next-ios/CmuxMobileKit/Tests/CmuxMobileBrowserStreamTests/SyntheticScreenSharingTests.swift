#if os(iOS)
import AVFoundation
import CmuxMobileTransport
import CoreVideo
import Darwin
import Foundation
import Testing
import UIKit
@testable import CmuxMobileBrowserStream

/// Synthetic host pictures, the real screen-share sink, VideoToolbox decoder and display
/// renderer. A decode callback alone is not presentation: read back the renderer's pixels.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct SyntheticScreenSharingTests {
    @Test(arguments: [320, 1280])
    func hostFramesReachTheViewerWithinBudget(width: Int32) async throws {
        let height: Int32 = width == 320 ? 240 : 720
        let count = 20
        let wallStart = ProcessInfo.processInfo.systemUptime
        let cpuStart = clock()
        let units = try DecoderTests.encode(frames: count, width: width, height: height)
        try #require(units.count == count, "the synthetic host must actually encode every frame")

        let model = StreamedBrowserModel(tab: "synthetic-screen", url: nil) { _ in FakeStream() }
        let sink = Sink(model: model)
        let decoded = DecoderTests.Collected()
        let originalShown = model.decoder.shown
        model.decoder.shown = { frame in
            decoded.lock.withLock { decoded.shown.append(frame) }
            originalShown(frame)
        }
        model.decoder.now = { DispatchTime.now().uptimeNanoseconds / 1_000 }

        // A real visible layer, without changing the simulator's key window or focus.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        let layer = model.decoder.layer
        layer.frame = window.bounds
        controller.view.layer.addSublayer(layer)
        window.isHidden = false
        defer {
            window.isHidden = true
            layer.removeFromSuperlayer()
            model.close()
        }

        var presented = 0
        var latencies: [Double] = []
        for (index, unit) in units.enumerated() {
            let received = DispatchTime.now().uptimeNanoseconds / 1_000
            sink.browserFrame(BrowserStreamFrame(stream: 0, frame: UInt32(index), keyframe: index == 0,
                                                accessUnit: unit, captureMicros: received,
                                                receivedMicros: received, ageMicros: 0))
            // The fixture paints each frame a different grey. Checking that grey catches a
            // frozen or stale display even when decoding and its callbacks continue to work.
            let grey = Int(UInt8(truncatingIfNeeded: 40 + index * 20))
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var matched = false
            repeat {
                // enqueue can present before the decoder queue invokes shown. Require both
                // events within this deadline rather than racing the final count assertion.
                if decoded.lock.withLock({ decoded.shown.last?.frame == UInt32(index) }),
                   let pixels = layer.sampleBufferRenderer.displayedPixelBuffer(),
                   Self.matches(pixels, grey: grey, width: width, height: height) {
                    matched = true
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            } while ProcessInfo.processInfo.systemUptime < deadline
            try #require(matched, "frame \(index) was not presented; renderer: \(layer.sampleBufferRenderer.status)")
            presented += 1
            latencies.append(Double(DispatchTime.now().uptimeNanoseconds / 1_000 - received) / 1_000)
        }

        let shown = decoded.lock.withLock { decoded.shown }
        #expect(shown.map(\.frame) == (0..<count).map(UInt32.init))
        #expect(shown.allSatisfy { !$0.held && $0.width == width && $0.height == height })
        #expect(presented == count)
        #expect(layer.sampleBufferRenderer.status != .failed)
        let p95 = latencies.sorted()[Int(ceil(Double(count) * 0.95)) - 1]
        #expect(p95 < 250, "delivery-to-displayed-pixels p95 must stay under 250 ms")
        let wall = ProcessInfo.processInfo.systemUptime - wallStart
        let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
        print("SCREEN_SHARE_SYNTHETIC width=\(width) height=\(height) received=\(units.count) decoded=\(shown.count) presented=\(presented) p95_ms=\(p95) wall_s=\(wall) process_cpu_s=\(cpu)")
    }

    private static func matches(_ pixels: CVPixelBuffer, grey: Int, width: Int32, height: Int32) -> Bool {
        guard CVPixelBufferGetWidth(pixels) == Int(width), CVPixelBufferGetHeight(pixels) == Int(height),
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(pixels)
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return false }
            let value = Int(base.assumingMemoryBound(to: UInt8.self).pointee)
            let expected = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ? 16 + Int((Double(grey) * 219 / 255).rounded()) : grey
            return abs(value - expected) <= 6
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return false }
            let values = base.assumingMemoryBound(to: UInt8.self)
            return (0..<3).allSatisfy { abs(Int(values[$0]) - grey) <= 6 }
        default:
            return false
        }
    }
}
#endif
