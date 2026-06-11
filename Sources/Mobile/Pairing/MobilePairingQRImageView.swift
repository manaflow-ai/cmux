import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders a payload string as a crisp QR code for the iOS pairing window.
///
/// The image is generated with `CIQRCodeGenerator` and scaled with no
/// interpolation so the modules stay sharp at the requested `dimension`.
struct MobilePairingQRImageView: View {
    /// The string encoded into the QR (the `cmux-ios://attach?...` URL).
    let payload: String
    /// The rendered side length, in points.
    let dimension: CGFloat
    /// The backing-store scale of the hosting screen. The bitmap is generated
    /// at device pixels (`dimension * displayScale`) so a Retina screen shows
    /// the generator's output directly instead of a 2x nearest-neighbor
    /// upscale of a point-sized bitmap.
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: dimension, height: dimension)
                    .accessibilityLabel(
                        String(
                            localized: "mobile.pairing.qrAccessibilityLabel",
                            defaultValue: "Pairing QR code"
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: dimension, height: dimension)
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.system(size: dimension * 0.3))
                            .foregroundStyle(.secondary)
                    )
                    .accessibilityLabel(
                        String(
                            localized: "mobile.pairing.qrUnavailable",
                            defaultValue: "Pairing code unavailable. Tap Refresh Code."
                        )
                    )
            }
        }
    }

    /// The payload rendered to an `NSImage` via Core Image, or `nil` if the
    /// generator produced no output for the given string.
    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // ECC L: the standard choice for screen-to-camera codes, where the
        // image is pristine (no print damage to correct for). The lower
        // redundancy drops the QR a version, so each module renders larger
        // at the same dimension and scans faster.
        filter.correctionLevel = "L"
        guard let output = filter.outputImage, output.extent.width > 0 else {
            return nil
        }
        // samplingNearest keeps module edges hard through the scale below;
        // Core Image's default linear sampling would feather them.
        let scale = dimension * max(1, displayScale) / output.extent.width
        let scaled = output.samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: dimension, height: dimension))
    }
}
