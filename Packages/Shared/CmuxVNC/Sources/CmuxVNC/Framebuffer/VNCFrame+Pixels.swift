#if !canImport(CoreVideo)
import Foundation

/// One presented state of the remote screen where CoreVideo does not exist
/// (VNCFrame.swift holds the pixel-buffer frame Apple presenters show): an
/// immutable copy of the framebuffer's words, `width` per row.
public struct VNCFrame: Sendable {
    /// `width * height` words, `0xAARRGGBB` (bytes `B G R A` in memory).
    public let pixels: [UInt32]
    public let width: Int
    public let height: Int
    /// Counts frames in this session, from 1.
    public let sequence: UInt64
    /// What changed since the previous frame, in framebuffer pixels.
    public let dirtyRect: CGRect
    /// `DispatchTime.now().uptimeNanoseconds` when the session published it.
    public var publishedAt: UInt64 = DispatchTime.now().uptimeNanoseconds

    /// Calls `body` with the words per row and a reader of the BGRA word at
    /// `y * rowPixels + x`, which `body` may ask only for x < width and
    /// y < height.
    func withWords<Result>(_ body: (_ rowPixels: Int, _ word: (Int) -> UInt32) -> Result) -> Result? {
        guard pixels.count >= width * height else { return nil }
        return body(width) { pixels[$0] }
    }
}

/// Copies the framebuffer's words into each frame; a frame never shares
/// storage the session writes again.
final class FramePublisher {
    private var sequence: UInt64 = 0

    func publish(_ framebuffer: Framebuffer, dirty: CGRect) -> VNCFrame? {
        let width = framebuffer.width, height = framebuffer.height
        guard width > 0, height > 0 else { return nil }
        sequence += 1
        return VNCFrame(pixels: framebuffer.pixels, width: width, height: height, sequence: sequence, dirtyRect: dirty)
    }
}
#endif
