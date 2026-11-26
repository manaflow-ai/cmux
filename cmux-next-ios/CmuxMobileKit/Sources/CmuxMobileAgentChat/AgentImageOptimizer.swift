#if canImport(ImageIO) && canImport(CoreGraphics)
import CmuxMobileArtifacts
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reduces in-memory image attachments before they become ACP image blocks.
///
/// Image attachments are base64 encoded in the prompt, so keeping camera and pasted
/// originals at their full pixel dimensions makes both the phone-to-Mac transfer and
/// the prompt unnecessarily large. Animated images stay untouched because a single
/// thumbnail would discard their animation.
enum AgentImageOptimizer {
    static let maxPixelSize = AttachmentImageEncoder.maxPixelSize
    static let jpegQuality = AttachmentImageEncoder.jpegQuality

    static func optimizeAsync(_ data: Data) async -> Data {
        await Task.detached(priority: .userInitiated) {
            optimize(data)
        }.value
    }

    /// Returns a smaller, orientation-correct image when ImageIO can decode it.
    /// The original bytes are retained when optimization would not save space.
    static func optimize(_ data: Data) -> Data {
        let needsAcceptedFormat = AgentAttachment(kind: .image, name: "image", data: data).imageMIMEType == nil
        return AttachmentImageEncoder.encode(data, allowLargerCopy: needsAcceptedFormat)?.data ?? data
    }

    static func filename(_ name: String, for data: Data) -> String {
        guard !URL(fileURLWithPath: name).pathExtension.isEmpty,
              let mime = AgentAttachment(kind: .image, name: name, data: data).imageMIMEType,
              let extensionName = UTType(mimeType: mime)?.preferredFilenameExtension else { return name }
        let url = URL(fileURLWithPath: name)
        guard url.pathExtension.caseInsensitiveCompare(extensionName) != .orderedSame else { return name }
        return url.deletingPathExtension().appendingPathExtension(extensionName).lastPathComponent
    }
}
#endif
