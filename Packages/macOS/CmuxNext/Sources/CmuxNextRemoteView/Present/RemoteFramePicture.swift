public import CoreGraphics
import VideoToolbox

extension RemoteDecodedFrame {
    /// This frame as a picture (a hidden remote tab's last frame, kept when it is discarded),
    /// converted off the main thread.
    @concurrent public nonisolated func picture() async -> CGImage? {
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }
}
