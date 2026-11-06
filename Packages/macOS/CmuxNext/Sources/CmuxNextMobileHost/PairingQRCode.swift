import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The Mobile Pairing page's QR code: CoreImage's `CIQRCodeGenerator`, one
/// pixel per module, dark on white with a quiet zone, as a PNG data URL the
/// page scales up without smoothing (`image-rendering: pixelated`). Dark on
/// white whatever the theme, so every camera reads it.
public struct PairingQRCode {
    private let context = CIContext(options: [.useSoftwareRenderer: true])

    public init() {}

    /// `data:image/png;base64,…` for `payload`, or nil when it cannot be encoded.
    public func pngDataURL(for payload: String, quiet: Int = 2) -> String? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              // concurrency-allow: software-renderer CIContext on one pairing QR code (at most ~180x180 modules); no GPU wait.
              let modules = context.createCGImage(output, from: output.extent) else { return nil }
        let side = modules.width + quiet * 2
        guard let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: side, height: side))
        bitmap.interpolationQuality = .none
        bitmap.draw(modules, in: CGRect(x: quiet, y: quiet, width: modules.width, height: modules.height))
        guard let image = bitmap.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
