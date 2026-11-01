import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Every frame the window server composites for one window of this process: the pixels a person
/// sees, not the model (ScreenCaptureKit with `SCShareableContent.currentProcess`, which asks for
/// no Screen Recording grant from macOS 14.4). Each complete frame keeps its display time and the
/// device pixels (BGRA) of one row and one column; the last complete frame can be read whole.
///
/// A frame ScreenCaptureKit reports idle (nothing changed) has no pixels; its count is kept, so a
/// test can tell a still window from a capture that stopped.
@available(macOS 14.4, *)
// crash-allow: every mutable field is read and written under `lock`, and ScreenCaptureKit calls back on `queue` only.
nonisolated final class WindowFrameStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// One complete frame.
    nonisolated struct Frame: Sendable {
        /// Host time in seconds (CACurrentMediaTime's clock) the frame was shown at.
        let time: Double
        /// The pixels of row `rowY`, left to right.
        let row: [UInt32]
        /// The pixels of column `columnX`, top to bottom.
        let column: [UInt32]
    }

    /// What ScreenCaptureKit said about the frames' size and scaling.
    nonisolated struct Shape: Sendable, Equatable {
        let width: Int
        let height: Int
        let scaleFactor: Double
        let contentScale: Double
    }

    /// One whole frame: `pixels[y * width + x]`, BGRA.
    nonisolated struct Image: Sendable {
        let width: Int
        let height: Int
        let pixels: [UInt32]
        func pixel(x: Int, y: Int) -> UInt32 { pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)] }
    }

    private let lock = NSLock()
    private var frames: [Frame] = []
    private var idle = 0
    private var stopped: String?
    /// The last complete frame's buffer (one buffer of the stream's queue of 8 held; copied only when asked).
    private var lastBuffer: CVPixelBuffer?
    private var shapes: [Shape] = []
    private var rowY: Int
    private var columnX: Int
    private let queue = DispatchQueue(label: "animation-pixel.capture", qos: .userInitiated)
    /// Touched on the main actor only (start, stop).
    private var stream: SCStream?

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// Keep every complete frame whole (``images``): for a small window only (golden compares).
    private let keepsImages: Bool
    private var images: [(time: Double, image: Image)] = []

    init(rowY: Int, columnX: Int, keepsImages: Bool = false) {
        self.rowY = rowY
        self.columnX = columnX
        self.keepsImages = keepsImages
        super.init()
    }

    /// Every complete frame, whole, when made with `keepsImages`.
    var capturedImages: [(time: Double, image: Image)] { lock.withLock { images } }

    /// Starts capturing `window` at its backing scale, one frame per display refresh or faster.
    @MainActor
    func start(window: NSWindow) async throws {
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw Failure(description: "ScreenCaptureKit lists no window \(window.windowNumber) of this process (\(content.windows.count) listed)")
        }
        let scale = window.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        // Faster than the display: ScreenCaptureKit then delivers every composited frame.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.captureResolution = .best
        // A narrower window (a resize test) is drawn 1:1, never scaled to the output size.
        configuration.scalesToFit = false
        // Past a narrower window the frame is transparent, so a resize test reads the window's width.
        configuration.backgroundColor = CGColor.clear
        configuration.ignoreShadowsSingleWindow = true
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    @MainActor
    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    var captured: [Frame] { lock.withLock { frames } }
    var idleFrames: Int { lock.withLock { idle } }
    var lastImage: Image? {
        lock.withLock {
            guard let buffer = lastBuffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var pixels = [UInt32](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes { out in
                guard let target = out.baseAddress else { return }
                for line in 0..<height {
                    target.advanced(by: line * width * 4).copyMemory(from: base.advanced(by: line * stride), byteCount: width * 4)
                }
            }
            return Image(width: width, height: height, pixels: pixels)
        }
    }
    /// Each distinct shape the frames had, in order.
    var frameShapes: [Shape] { lock.withLock { shapes } }
    /// Why the stream stopped by itself, if it did.
    var stopError: String? { lock.withLock { stopped } }

    func moveScanlines(rowY: Int, columnX: Int) {
        lock.withLock {
            self.rowY = rowY
            self.columnX = columnX
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            lock.withLock { idle += 1 }
            return
        }
        let ticks = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let (y, x) = lock.withLock { (min(max(rowY, 0), height - 1), min(max(columnX, 0), width - 1)) }
        let row = (0..<width).map { base.load(fromByteOffset: y * stride + $0 * 4, as: UInt32.self) }
        let column = (0..<height).map { base.load(fromByteOffset: $0 * stride + x * 4, as: UInt32.self) }
        let shape = Shape(width: width, height: height, scaleFactor: (info[.scaleFactor] as? NSNumber)?.doubleValue ?? 0,
                          contentScale: (info[.contentScale] as? NSNumber)?.doubleValue ?? 0)
        let frame = Frame(time: Double(ticks) * Self.secondsPerTick, row: row, column: column)
        var whole: Image?
        if keepsImages {
            var pixels = [UInt32](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes { out in
                guard let target = out.baseAddress else { return }
                for line in 0..<height {
                    target.advanced(by: line * width * 4).copyMemory(from: base.advanced(by: line * stride), byteCount: width * 4)
                }
            }
            whole = Image(width: width, height: height, pixels: pixels)
        }
        lock.withLock {
            frames.append(frame)
            if let whole { images.append((time: frame.time, image: whole)) }
            lastBuffer = buffer
            if shapes.last != shape { shapes.append(shape) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { stopped = String(describing: error) }
    }
}
