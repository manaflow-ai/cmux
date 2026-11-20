import CoreGraphics
import Foundation
import ImageIO

extension AttachmentMedia {
    /// A link preview's picture as the owner takes it (`link_preview.image`:
    /// JPEG or WebP, at most `previewMaxBytes`): a JPEG at most
    /// `previewMaxPixel` on its long edge, smaller and at lower quality until
    /// it fits. Transparent pixels are drawn over white (a JPEG has no alpha
    /// and would show them black). Nil when the file is not an image or no
    /// attempt fits.
    static func linkPreviewJPEG(of url: URL) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let maxPixel = HomeAttachmentPolicy.previewMaxPixel
        for (pixels, quality) in [(maxPixel, 0.8), (maxPixel, 0.6), (maxPixel * 3 / 4, 0.6), (maxPixel / 2, 0.6), (maxPixel / 4, 0.5)] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let opaque = flattened(image),
                  let data = try? jpeg(opaque, quality: quality) else { return nil }
            if data.count <= HomeAttachmentPolicy.previewMaxBytes { return (data, opaque.width, opaque.height) }
        }
        return nil
    }

    /// The image over white, without an alpha channel.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// The picture in the blob cache as an image attachment of its own
    /// (`link-preview.jpg`, no preview or poster: it is already small).
    static func prepareLinkPreviewImage(fileURL: URL, root: URL) throws -> LocalAttachment {
        guard let picture = linkPreviewJPEG(of: fileURL) else { throw HomeRejection.invalid("not_an_image") }
        let (hash, url) = try ingest(data: picture.data, fileExtension: "jpg", root: root)
        let ref = AttachmentRef(hash: hash, name: "link-preview.jpg", mimeType: "image/jpeg", byteCount: picture.data.count,
                                width: picture.width, height: picture.height)
        return LocalAttachment(ref: HomeAttachmentPolicy.normalized(ref), fileURL: url)
    }
}
