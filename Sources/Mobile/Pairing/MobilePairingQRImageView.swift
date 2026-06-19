import AppKit
import CMUXMobileCore
import SwiftUI

/// Renders a payload string as a crisp, square QR code for the iOS pairing
/// window.
///
/// The view is flexible: it fills whatever width the layout offers (keeping a
/// 1:1 aspect), so the pairing window can show the code as large as possible.
/// ``CmxPairingQRBitmap`` supplies the bitmap at one pixel per module, pure
/// black on pure white, ECC M, with the full 4-module quiet zone baked in so
/// the white margin scales with the code and cannot be cropped by layout.
/// SwiftUI upscales it with interpolation disabled, so every module stays a
/// sharp nearest-neighbor square at any display size and backing scale.
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

    /// The payload rendered at native module resolution, or `nil` if the
    /// generator produced no output for the given string. No scaling happens
    /// here; the view upscales with interpolation disabled so modules stay
    /// sharp.
    private var qrImage: NSImage? {
        guard let cgImage = CmxPairingQRBitmap().makeImage(payload: payload) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
    }
}
