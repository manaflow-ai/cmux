internal import CoreGraphics
public import Foundation
internal import ImageIO

/// Downsamples image files into bounded upload bytes without decoding a full raster.
public struct MobileImageAttachmentPreparer: Sendable {
    /// Source-file ceiling checked before ImageIO opens the file.
    public static let maximumRawInputBytes = 60 * 1024 * 1024
    /// Encoded upload ceiling shared by terminal and task attachments.
    public static let maximumEncodedBytes = 8 * 1024 * 1024

    private let sendMaxPixelSize = 2_048
    private let thumbnailMaxPixelSize = 384

    /// Creates a reusable image attachment preparer.
    public init() {}

    /// Prepares one file-backed image in a cancellable background child task.
    ///
    /// ImageIO opens the file URL lazily and downsamples before decoding, so a
    /// large HEIC, panorama, or RAW source never becomes a full-size in-memory
    /// raster.
    ///
    /// - Parameter url: A readable local image file.
    /// - Returns: Bounded PNG/JPEG bytes plus a thumbnail, or `nil` when the
    ///   source is invalid, oversized after compression, or cancelled.
    public nonisolated func prepare(url: URL) async -> MobilePreparedImageAttachment? {
        guard !Task.isCancelled else { return nil }
        return await withTaskGroup(of: MobilePreparedImageAttachment?.self) { group in
            group.addTask(priority: .background) {
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let payload = boundedSendPayload(from: source) else {
                    return nil
                }
                guard !Task.isCancelled else { return nil }
                return MobilePreparedImageAttachment(
                    data: payload.data,
                    format: payload.format,
                    thumbnailData: downsampledImageData(
                        from: source,
                        maxPixelSize: thumbnailMaxPixelSize,
                        type: "public.png",
                        jpegQuality: nil
                    )
                )
            }
            return await group.next() ?? nil
        }
    }

    private nonisolated func boundedSendPayload(
        from source: CGImageSource
    ) -> (data: Data, format: String)? {
        if let png = downsampledImageData(
            from: source,
            maxPixelSize: sendMaxPixelSize,
            type: "public.png",
            jpegQuality: nil
        ), png.count <= Self.maximumEncodedBytes {
            return (png, "png")
        }
        for quality in [0.8, 0.6, 0.4] as [CGFloat] {
            if let jpeg = downsampledImageData(
                from: source,
                maxPixelSize: sendMaxPixelSize,
                type: "public.jpeg",
                jpegQuality: quality
            ), jpeg.count <= Self.maximumEncodedBytes {
                return (jpeg, "jpg")
            }
        }
        for maxPixelSize in [1_536, 1_024, 768] {
            if let jpeg = downsampledImageData(
                from: source,
                maxPixelSize: maxPixelSize,
                type: "public.jpeg",
                jpegQuality: 0.5
            ), jpeg.count <= Self.maximumEncodedBytes {
                return (jpeg, "jpg")
            }
        }
        return nil
    }

    private nonisolated func downsampledImageData(
        from source: CGImageSource,
        maxPixelSize: Int,
        type: String,
        jpegQuality: CGFloat?
    ) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            type as CFString,
            1,
            nil
        ) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let jpegQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
