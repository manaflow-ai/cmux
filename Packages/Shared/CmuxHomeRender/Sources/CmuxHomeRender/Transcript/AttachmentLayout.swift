import CmuxHomeCore
import CoreGraphics
import CoreText
import Foundation

/// Layout of attachment parts.
enum AttachmentLayout {
    /// Image types ImageIO decodes (vector formats stay files).
    static let imageTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/heic", "image/heif", "image/webp", "image/tiff", "image/bmp",
    ]
    /// Video types AVFoundation plays on macOS and iOS.
    static let videoTypes: Set<String> = ["video/mp4", "video/quicktime", "video/x-m4v", "video/3gpp"]

    /// Media need a pixel size to lay out before the bytes; without one an
    /// image or video shows as a file chip.
    static func media(_ ref: AttachmentRef) -> MediaPart? {
        guard let w = ref.width, let h = ref.height, w > 0, h > 0 else { return nil }
        let type = HomeAttachmentPolicy.canonicalMimeType(ref.mimeType)
        if imageTypes.contains(type) { return MediaPart(ref: ref, isVideo: false) }
        if videoTypes.contains(type) { return MediaPart(ref: ref, isVideo: true) }
        return nil
    }

    /// Media at their 2x point size, at most 300 pt wide (and never wider
    /// than the text column) and 360 pt tall; a taller image is cropped.
    static let mediaMaxWidth: CGFloat = 300
    static let mediaMaxHeight: CGFloat = 360
    static let mediaMinSide: CGFloat = 24

    static func mediaSize(_ ref: AttachmentRef, metrics: Metrics) -> CGSize {
        let pw = CGFloat(max(1, ref.width ?? 1)), ph = CGFloat(max(1, ref.height ?? 1))
        let cap = min(mediaMaxWidth, metrics.maxTextWidth + 2 * Style.bubblePadX)
        let w = max(min(cap, mediaMinSide), min(cap, (pw / 2).rounded()))
        let h = min(mediaMaxHeight, max(mediaMinSide, (w * ph / pw).rounded()))
        return CGSize(width: w, height: h)
    }

    static func content(of ref: AttachmentRef, metrics: Metrics) -> (PartContent, CGSize) {
        if let media = media(ref) { return (.media(media), mediaSize(ref, metrics: metrics)) }
        let maxWidth = min(FileChip.maxWidth, metrics.maxTextWidth + 2 * Style.bubblePadX)
        let kind = fileKind(ref)
        let size = ByteCountFormatter.string(fromByteCount: Int64(ref.byteCount), countStyle: .file)
        let detail = kind + " \u{00B7} " + size
        let textRoom = maxWidth - FileChip.textLeft - FileChip.padRight
        let name = truncateMiddle(ref.name, font: FileChip.nameFont, width: textRoom)
        let used = max(TextDraw.width(name, font: FileChip.nameFont), TextDraw.width(detail, font: FileChip.detailFont))
        let width = min(maxWidth, max(FileChip.minWidth, (FileChip.textLeft + used + FileChip.padRight).rounded(.up)))
        let part = FilePart(name: name, fullName: ref.name, kind: kind, size: size, badge: badge(ref), hash: ref.hash)
        return (.file(part), CGSize(width: width, height: FileChip.height))
    }

    static func fileKind(_ ref: AttachmentRef) -> String {
        let type = HomeAttachmentPolicy.canonicalMimeType(ref.mimeType)
        let ext = (ref.name as NSString).pathExtension.lowercased()
        if type == "application/pdf" || ext == "pdf" { return AttachmentStrings.kindPDF }
        if ["application/zip", "application/x-tar", "application/gzip", "application/x-7z-compressed"].contains(type)
            || ["zip", "tar", "gz", "tgz", "7z"].contains(ext) { return AttachmentStrings.kindArchive }
        if type.hasPrefix("image/") { return AttachmentStrings.kindImage }
        if type.hasPrefix("video/") { return AttachmentStrings.kindVideo }
        if type.hasPrefix("audio/") { return AttachmentStrings.kindAudio }
        if type.hasPrefix("text/") { return AttachmentStrings.kindText }
        return AttachmentStrings.kindDocument
    }

    static func badge(_ ref: AttachmentRef) -> String {
        let ext = (ref.name as NSString).pathExtension.uppercased()
        return String(ext.prefix(4))
    }

    /// `name` shortened in the middle with an ellipsis until it fits `width`.
    static func truncateMiddle(_ name: String, font: CTFont, width: CGFloat) -> String {
        guard TextDraw.width(name, font: font) > width, name.count > 3 else { return name }
        var chars = Array(name)
        while chars.count > 3 {
            let cut = chars.count / 2
            chars.remove(at: cut)
            let candidate = String(chars[..<cut]) + "\u{2026}" + String(chars[cut...])
            if TextDraw.width(candidate, font: font) <= width { return candidate }
        }
        return String(chars)
    }
}

/// File chip geometry (points, relative to the chip body).
enum FileChip {
    static let height: CGFloat = 56
    static let maxWidth: CGFloat = 275
    static let minWidth: CGFloat = 160
    static let icon = CGRect(x: 12, y: 10, width: 28, height: 36)
    static let textLeft: CGFloat = 50
    static let padRight: CGFloat = 14
    static let nameBaseline: CGFloat = 25
    static let detailBaseline: CGFloat = 42
    nonisolated(unsafe) static let nameFont = Fonts.system(13, .semibold)
    nonisolated(unsafe) static let detailFont = Fonts.system(11)
    nonisolated(unsafe) static let badgeFont = Fonts.system(7, .bold)
}
