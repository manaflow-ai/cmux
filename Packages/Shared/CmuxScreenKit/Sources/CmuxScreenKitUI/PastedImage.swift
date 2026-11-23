#if os(iOS)
import CmuxScreenKit
import UIKit

/// A photo from the picker, in a form the Mac's pasteboard takes: PNG and
/// JPEG as they are (a screenshot stays sharp); anything else (HEIC, …)
/// decoded and sent as PNG when it has transparency, JPEG otherwise, no
/// larger than ``maximumLongEdge`` and ``ScreenInput/pasteImageMaximumBytes``.
struct PastedImage: Sendable, Equatable {
    let data: Data
    /// The uniform type identifier (`public.png`, `public.jpeg`).
    let type: String

    /// A 4K display's long edge: larger photos are scaled down when re-encoded.
    static let maximumLongEdge: CGFloat = 4096

    init(data: Data, type: String) {
        self.data = data
        self.type = type
    }

    /// Nil when `photo` is no image, or cannot be made small enough.
    init?(photo: Data) {
        let limit = ScreenInput.pasteImageMaximumBytes
        if photo.count <= limit, let type = Self.passThroughType(of: photo) {
            self.init(data: photo, type: type)
            return
        }
        guard let image = UIImage(data: photo), let encoded = Self.encode(image, limit: limit) else { return nil }
        self = encoded
    }

    /// `public.png` or `public.jpeg` from the file's signature; nil for any other format.
    static func passThroughType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "public.png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "public.jpeg" }
        return nil
    }

    private static func encode(_ image: UIImage, limit: Int) -> PastedImage? {
        var edge = min(maximumLongEdge, max(image.size.width * image.scale, image.size.height * image.scale))
        let transparent = hasAlpha(image)
        // Halve the size until it fits (a huge PNG; JPEG nearly always fits at once). A small
        // image (a sticker under 256 px) still gets its one try at full size.
        repeat {
            let scaled = scale(image, longEdge: edge)
            if transparent, let png = scaled.pngData(), png.count <= limit { return PastedImage(data: png, type: "public.png") }
            if let jpeg = scaled.jpegData(compressionQuality: 0.9), jpeg.count <= limit { return PastedImage(data: jpeg, type: "public.jpeg") }
            edge /= 2
        } while edge >= 256
        return nil
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        switch image.cgImage?.alphaInfo {
        case .first?, .last?, .premultipliedFirst?, .premultipliedLast?: true
        default: false
        }
    }

    private static func scale(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, longEdge / max(pixels.width, pixels.height, 1))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
