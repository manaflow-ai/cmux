import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A crisp QR code for `text`, scaled with nearest-neighbor sampling.
/// Rendering reads back from the GPU, so callers run it off the main actor.
struct QRCodeImage: Sendable {
    nonisolated func make(_ text: String, pixels: CGFloat) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let factor = max(1, (pixels / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        // concurrency-allow: only called from a detached task (PhonePairingView.renderCode), never on the main thread
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
