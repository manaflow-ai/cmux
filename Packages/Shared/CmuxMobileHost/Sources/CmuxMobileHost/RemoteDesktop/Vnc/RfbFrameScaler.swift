import CoreVideo
import VideoToolbox

/// Scales a BGRA buffer down to the view's pixel size with
/// VTPixelTransferSession. Not Sendable: one target actor owns it.
final class RfbFrameScaler {
    private var session: VTPixelTransferSession?

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    /// `source` itself when it already fits, else a scaled copy (aspect kept
    /// by the caller's size).
    func scale(_ source: CVPixelBuffer, toWidth width: Int, height: Int) -> CVPixelBuffer {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0, width < sourceWidth || height < sourceHeight else { return source }
        if session == nil { VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) }
        guard let session else { return source }
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &output) == kCVReturnSuccess,
              let output, VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr else { return source }
        return output
    }
}
