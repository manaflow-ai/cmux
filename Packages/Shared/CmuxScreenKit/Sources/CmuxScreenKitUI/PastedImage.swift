#if os(iOS)
import CmuxScreenKit
import UIKit

/// A photo from the picker, in a form the Mac's pasteboard takes, at its full size: PNG and JPEG
/// as they are; anything else (HEIC, …) decoded and sent as PNG when it has transparency, JPEG
/// otherwise. No size limit: the image goes to the Mac in chunks (``ScreenInput/pasteImage(_:type:id:)``).
struct PastedImage: Sendable, Equatable {
    let data: Data
    /// The uniform type identifier (`public.png`, `public.jpeg`).
    let type: String

    init(data: Data, type: String) {
        self.data = data
        self.type = type
    }

    /// Nil when `photo` is no image, or cannot be encoded.
    init?(photo: Data) {
        if let type = Self.passThroughType(of: photo) {
            self.init(data: photo, type: type)
            return
        }
        guard let image = UIImage(data: photo), let encoded = Self.encode(image) else { return nil }
        self = encoded
    }

    /// `public.png` or `public.jpeg` from the file's signature; nil for any other format.
    static func passThroughType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "public.png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "public.jpeg" }
        return nil
    }

    /// One encode at the image's own pixel size (drawn once, so its orientation is applied): PNG
    /// when it has transparency, JPEG otherwise.
    private static func encode(_ image: UIImage) -> PastedImage? {
        let upright = drawn(image)
        if hasAlpha(image), let png = upright.pngData() { return PastedImage(data: png, type: "public.png") }
        return upright.jpegData(compressionQuality: 0.9).map { PastedImage(data: $0, type: "public.jpeg") }
    }

    /// `image` drawn at its full pixel size, upright.
    private static func drawn(_ image: UIImage) -> UIImage {
        let size = CGSize(width: (image.size.width * image.scale).rounded(), height: (image.size.height * image.scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        switch image.cgImage?.alphaInfo {
        case .first?, .last?, .premultipliedFirst?, .premultipliedLast?: true
        default: false
        }
    }
}
#endif
