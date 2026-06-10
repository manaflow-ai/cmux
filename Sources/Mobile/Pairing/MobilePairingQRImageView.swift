import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Renders a payload string as a crisp, square QR code for the iOS pairing
/// window.
///
/// The view is flexible: it fills whatever width the layout offers (keeping a
/// 1:1 aspect), so the pairing window can show the code as large as possible.
/// The image is generated once at the QR's native module resolution (one
/// pixel per module) and upscaled by SwiftUI with interpolation disabled, so
/// every module stays a sharp nearest-neighbor square at any display size and
/// backing scale. The caller supplies the surrounding quiet zone (white
/// padding); the generator's own 1-module margin alone is below spec.
struct MobilePairingQRImageView: View {
    /// The string encoded into the QR (the `cmux-ios://attach?...` URL).
    let payload: String

    var body: some View {
        Group {
            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel(
                        String(
                            localized: "mobile.pairing.qrAccessibilityLabel",
                            defaultValue: "Pairing QR code"
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.system(size: 48))
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

    /// The payload rendered to an `NSImage` at native module resolution via
    /// Core Image, or `nil` if the generator produced no output for the given
    /// string. No scaling happens here; the view upscales with interpolation
    /// disabled so modules stay sharp.
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
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: output.extent.width, height: output.extent.height)
        )
    }
}
