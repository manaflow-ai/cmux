import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR codes from CoreImage's `CIQRCodeGenerator`: one pixel per module,
/// dark modules on white with a quiet zone, scaled up without smoothing.
/// Always dark on white, whatever the theme, so every camera reads it.
enum QRCode {
    private static var cache: [String: CGImage] = [:]
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    /// The code for `payload` with a `quiet`-module border, one pixel per
    /// module, cached per payload.
    static func image(for payload: String, quiet: Int = 2) -> CGImage? {
        let key = "\(quiet):\(payload)"
        if let cached = cache[key] { return cached }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let modules = context.createCGImage(output, from: output.extent) else { return nil }
        let side = modules.width + quiet * 2
        guard let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: side, height: side))
        bitmap.interpolationQuality = .none
        bitmap.draw(modules, in: CGRect(x: quiet, y: quiet, width: modules.width, height: modules.height))
        let image = bitmap.makeImage()
        cache[key] = image
        return image
    }
}

/// A QR code on a white rounded tile.
struct QRCodeImage: View {
    let payload: String

    var body: some View {
        if let image = QRCode.image(for: payload) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
