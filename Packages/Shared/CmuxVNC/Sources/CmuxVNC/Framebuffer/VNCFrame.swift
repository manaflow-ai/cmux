import CoreGraphics
import CoreVideo
import Foundation

/// One presented state of the remote screen: an IOSurface-backed 32BGRA
/// pixel buffer the session never writes again, so presenters may show it
/// directly (`CALayer.contents`, Metal, `CGImage`).
// crash-allow: every field is immutable and the pixel buffer is never written after publish() fills it, before any thread sees the frame.
public struct VNCFrame: @unchecked Sendable {
    // @unchecked: the session fills the buffer before it hands the frame out
    // and never touches it again.
    public let pixelBuffer: CVPixelBuffer
    public let width: Int
    public let height: Int
    /// Counts frames in this session, from 1.
    public let sequence: UInt64
    /// What changed since the previous frame, in framebuffer pixels.
    public let dirtyRect: CGRect
    /// `DispatchTime.now().uptimeNanoseconds` when the session published it.
    public var publishedAt: UInt64 = DispatchTime.now().uptimeNanoseconds

    /// A `CGImage` over a copy of the pixels (for UIKit/AppKit views that
    /// do not take pixel buffers).
    public func makeImage() -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        // SAFETY: the buffer is locked until the defer, so its base address stays valid while
        // the copy below reads it.
        guard let base = unsafe CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        // SAFETY: a locked 32BGRA buffer of `height` rows holds stride * height bytes at
        // `base`; Data copies them before the defer unlocks the buffer.
        let data = unsafe Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        // SAFETY: a nil decode array: CGImage reads no decode values; the provider owns a copy of the bytes.
        return unsafe CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Copies the framebuffer into pooled pixel buffers. A pool buffer is
/// reused only after every presenter released it.
final class FramePublisher {
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var sequence: UInt64 = 0

    func publish(_ framebuffer: Framebuffer, dirty: CGRect) -> VNCFrame? {
        let width = framebuffer.width, height = framebuffer.height
        guard width > 0, height > 0, let buffer = makeBuffer(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // SAFETY: the buffer is locked for writing until the defer; the copy below runs before it.
        guard let base = unsafe CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width * 4 else { return nil }
        framebuffer.pixels.withUnsafeBytes { source in
            // SAFETY: the start of the framebuffer's words, valid for this closure.
            guard let from = unsafe source.baseAddress else { return }
            for row in 0 ..< height {
                // SAFETY: the framebuffer holds width * height words, so `from` starts width * height * 4
                // bytes. The pool buffer is width x height 32BGRA with `stride` >= width * 4 bytes a row
                // (checked above), so this writes width * 4 bytes at row * stride, inside its
                // stride * height bytes, and reads width * 4 bytes at row * width * 4, inside the words.
                // Both ranges stay valid until the closure and the lock end.
                unsafe (base + row * stride).copyMemory(from: from + row * width * 4, byteCount: width * 4)
            }
        }
        sequence += 1
        return VNCFrame(pixelBuffer: buffer, width: width, height: height, sequence: sequence, dirtyRect: dirty)
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var created: CVPixelBufferPool?
            // SAFETY: CVPixelBufferPoolCreate stores at most one +1 pool in the local `created`,
            // live for this call; the Swift import takes ownership of it.
            _ = unsafe CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                               attributes as CFDictionary, &created)
            pool = created
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        // SAFETY: stores at most one +1 pixel buffer in the local `buffer`, live for this call.
        _ = unsafe CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
