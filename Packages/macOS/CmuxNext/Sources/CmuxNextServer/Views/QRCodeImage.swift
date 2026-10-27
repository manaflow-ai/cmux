import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// memory: fixed the `kept` (4) most recent payloads, each at most 181 rows of 181 one-byte pixels
// (version 40 with the default quiet zone) that CoreGraphics pads to 192 bytes: about 35 KB each.
/// QR codes from CoreImage's `CIQRCodeGenerator`: one pixel per module,
/// dark modules on white with a quiet zone, scaled up without smoothing.
/// Always dark on white, whatever the theme, so every camera reads it.
enum QRCode {
    /// Codes kept: a pairing sheet shows one, and each pairing has a new payload.
    static let kept = 4
    /// Least recently drawn first.
    private static var cache: [(key: String, image: CGImage)] = []
    private static let context = CIContext(options: [.useSoftwareRenderer: true])

    /// The code for `payload` with a `quiet`-module border, one pixel per
    /// module, cached for the ``kept`` most recent payloads.
    static func image(for payload: String, quiet: Int = 2) -> CGImage? {
        let key = "\(quiet):\(payload)"
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let hit = cache.remove(at: index)
            cache.append(hit)
            return hit.image
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              // concurrency-allow: software-renderer CIContext on a pairing QR code (at most ~180x180 modules), cached per payload; no GPU wait.
              let modules = context.createCGImage(output, from: output.extent) else { return nil }
        let side = modules.width + quiet * 2
        guard let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: side, height: side))
        bitmap.interpolationQuality = .none
        bitmap.draw(modules, in: CGRect(x: quiet, y: quiet, width: modules.width, height: modules.height))
        guard let image = bitmap.makeImage() else { return nil }
        cache.append((key, image))
        if cache.count > kept { cache.removeFirst(cache.count - kept) }
        return image
    }

    /// How many codes are kept now.
    static var count: Int { cache.count }
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
