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
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else {
            return nil
        }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: dimension, height: dimension))
    }
}
