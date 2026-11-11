import CmuxScreenKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo from the picker, in a form the Mac's pasteboard takes, at its full size: PNG and JPEG
/// as they are; anything else (HEIC, …) converted by ImageIO, source to destination, as PNG when it
/// has transparency, JPEG otherwise. ImageIO carries the orientation and the other metadata across,
/// and no drawing context is made here (UIKit's renderer added a second full-size bitmap: about 190 MB
/// for a 48 MP photo). No size limit: the image goes to the Mac in chunks
/// (``ScreenInput/pasteImageChunks(_:type:id:)``). Builds on macOS too, so its tests run there.
struct PastedImage: Sendable, Equatable {
    let data: Data
    /// The uniform type identifier (`public.png`, `public.jpeg`).
    let type: String

    init(data: Data, type: String) {
        self.data = data
        self.type = type
    }

    /// Nil when `photo` is no image, or cannot be converted.
    init?(photo: Data) {
        if let type = Self.passThroughType(of: photo) {
            self.init(data: photo, type: type)
            return
        }
        guard let converted = Self.convert(photo) else { return nil }
        self = converted
    }

    /// `public.png` or `public.jpeg` from the file's signature; nil for any other format.
    static func passThroughType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "public.png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "public.jpeg" }
        return nil
    }

    /// The photo's first image re-encoded by ImageIO at its full size: PNG with transparency, else JPEG.
    private static func convert(_ photo: Data) -> PastedImage? {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let transparent = properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
        let type = transparent ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = transparent ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PastedImage(data: output as Data, type: type.identifier)
    }
}
