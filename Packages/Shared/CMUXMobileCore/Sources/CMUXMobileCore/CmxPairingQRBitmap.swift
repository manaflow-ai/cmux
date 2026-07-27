import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders a pairing payload string as a scanner-friendly QR bitmap.
///
/// The rendering half of the pairing-QR domain (``CmxPairingQRCode`` is the
/// payload half). The output is one pixel per module, pure black on pure
/// white, with the full ISO/IEC 18004 quiet zone baked into the bitmap, so
/// the white margin scales with the code no matter how the host view lays it
/// out and stays white regardless of app theme. Callers upscale with
/// interpolation disabled to keep every module a sharp square.
public struct CmxPairingQRBitmap: Sendable {
    /// Quiet-zone width baked around the code, in modules. Four is the
    /// ISO/IEC 18004 minimum; scanners (third-party ones especially)
    /// routinely fail on codes whose surrounding white margin is thinner.
    public static let quietZoneModules = 4

    /// Creates the renderer. It is stateless: construct one inline at the
    /// call site.
    public init() {}

    /// Renders `payload` to a one-pixel-per-module `CGImage` with the quiet
    /// zone included, or `nil` when Core Image produces no code (empty or
    /// over-capacity payload).
    ///
    /// ECC M rather than L: the routes-only payload is small enough that M
    /// still keeps the code at QR version 6 or lower (asserted by tests), and
    /// the extra redundancy tolerates the glare, moire, and off-angle blur of
    /// photographing a glossy Mac screen. L would maximize module size, but
    /// module size is not the binding constraint at these payload sizes.
    public func makeImage(payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else {
            return nil
        }
        // The generator emits pure black-on-white at one pixel per module
        // with a 1-module margin; composite over white to widen that margin
        // to the full quiet zone.
        let padding = CGFloat(Self.quietZoneModules - 1)
        let paddedRect = output.extent.insetBy(dx: -padding, dy: -padding)
        let white = CIImage(color: .white).cropped(to: paddedRect)
        let composited = output.composited(over: white)
        return CIContext().createCGImage(composited, from: paddedRect)
    }
}
