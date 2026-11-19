#if os(iOS) && DEBUG
import CmuxMobileBrowserStream
import CmuxMobileLinkFFI
import CoreVideo
import Foundation
import os
import QuartzCore

private let log = Logger(subsystem: "dev.cmux.mobile", category: "screen-k2f")

/// Test-only key-to-frame probe (DEBUG builds, opted in by launch environment): the time from
/// this phone sending a key to the frame showing its effect presented here, p50 / p95, against
/// the host's glass-to-glass marker. The loop, the marker read, the matching and probe.json are
/// Rust (`KeyToFrameProbe`, cmux-mobile-link-ffi `key_to_frame.rs`); this file only reads 20
/// luma bytes from each decoded picture and says when it reaches the glass.
///
/// - `CMUX_K2F_MARKER`: `CELL_FRACTION,ORIGIN_Y` (one marker cell's width over the frame width,
///   the marker's top over the frame height), as RdMarkerClickLatencyTests takes them. Required.
/// - `CMUX_K2F_SAMPLES` (300), `CMUX_K2F_INPUT` (`key` or `click`), `CMUX_K2F_OUT` (a directory;
///   Documents/k2f by default): probe.json and samples.jsonl go there, and probe.json's text is
///   printed as one `k2f: {...}` line.
final class ScreenKeyToFrame: @unchecked Sendable {
    let probe: KeyToFrameProbe
    let samples: UInt32
    let mode: String
    let outDir: String
    private let vsync = VsyncClock()
    private let points = OSAllocatedUnfairLock<(size: (UInt32, UInt32), points: [MarkerPoint])>(
        initialState: ((0, 0), []))

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let parts = (environment["CMUX_K2F_MARKER"] ?? "").split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        probe = KeyToFrameProbe(geometry: MarkerGeometry(cellFraction: parts[0], originY: parts[1]))
        samples = UInt32(environment["CMUX_K2F_SAMPLES"] ?? "") ?? 300
        mode = environment["CMUX_K2F_INPUT"] ?? "key"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        outDir = environment["CMUX_K2F_OUT"] ?? documents.appendingPathComponent("k2f").path
    }

    /// Reads every picture `decoder` shows and runs the probe on its own thread through `input`.
    func start(decoder: BrowserVideoDecoder, input: any KeyToFrameInput, meta: [String: String]) {
        Task { @MainActor [vsync] in vsync.start() }
        decoder.enqueued = { [self] pixels in read(pixels) }
        let metaJSON = (try? JSONSerialization.data(withJSONObject: meta)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let thread = Thread { [self] in
            do {
                let text = try probe.run(input: input, mode: mode, samples: samples, outDir: outDir, metaJson: metaJSON)
                print("k2f: \(text)")
            } catch {
                log.error("key-to-frame probe failed: \(String(describing: error), privacy: .public)")
                print("k2f-error: \(error)")
            }
        }
        thread.name = "cmux-k2f"
        thread.start()
    }

    /// On the decode queue, right after the picture went to the layer.
    private func read(_ pixels: CVPixelBuffer) {
        let decoded = keyToFrameClockUs()
        let width = UInt32(CVPixelBufferGetWidth(pixels))
        let height = UInt32(CVPixelBufferGetHeight(pixels))
        let at = points.withLock { cache -> [MarkerPoint] in
            if cache.size != (width, height) { cache = ((width, height), probe.markerPoints(width: width, height: height)) }
            return cache.points
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let lumas = Data(at.map { bytes[Int($0.y) * stride + Int($0.x)] })
        let now = CACurrentMediaTime()
        let presented = decoded &+ UInt64(max(0, vsync.nextPresent(after: now) - now) * 1_000_000)
        _ = probe.frame(width: width, height: height, lumas: lumas, decodedUs: decoded, presentedUs: presented)
    }
}

/// The display's refresh: a picture handed to an `AVSampleBufferDisplayLayer` with
/// DisplayImmediately reaches the glass at the next vsync (the layer reports no per-frame
/// present time, so this is the estimate probe.json's meta names).
private final class VsyncClock: NSObject, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(target: CFTimeInterval, period: CFTimeInterval)>(initialState: (0, 0))
    private var link: CADisplayLink?

    @MainActor func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        let period = link.targetTimestamp - link.timestamp
        state.withLock { $0 = (target, period) }
    }

    /// The first vsync at or after `now` (CACurrentMediaTime seconds).
    func nextPresent(after now: CFTimeInterval) -> CFTimeInterval {
        let (target, period) = state.withLock { $0 }
        guard period > 0, target > 0 else { return now }
        if target >= now { return target }
        return target + (((now - target) / period).rounded(.up)) * period
    }
}
#endif
