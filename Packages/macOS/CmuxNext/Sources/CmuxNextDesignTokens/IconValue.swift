public import Foundation

/// The one icon value every object uses (R94; the page side is
/// webviews/src/icon-picker/iconValue.ts): an emoji, an SF Symbol name, a
/// raster image asset or a sanitized SVG asset. Assets are content addressed
/// (`sha256-<64 hex>`) and stored once by the object's owner.
///
/// Wire form: the objects' existing `icon` string fields, so stored rows and
/// old readers stay valid:
/// - one emoji -> `.emoji`
/// - `[a-z0-9]+(.[a-z0-9]+)*` -> `.symbol`
/// - `image:sha256-<hex>` -> `.image`
/// - `svg:sha256-<hex>` -> `.svg`
///
/// This is the only "is this an emoji or a symbol?" rule in the app; the
/// daemon's `validate_presentation_icon` is the authority on what is stored.
public nonisolated enum IconValue: Hashable, Sendable {
    case emoji(String)
    case symbol(String)
    case image(String)
    case svg(String)

    /// Longest accepted emoji, in UTF-8 bytes (the daemon's limit).
    public static let maxEmojiBytes = 32
    /// Longest accepted SF Symbol name, in bytes (the daemon's limit).
    public static let maxSymbolBytes = 128

    /// The value of a wire `icon` string; nil when it is none of the four forms.
    public init?(wire: String?) {
        guard let wire, !wire.isEmpty else { return nil }
        if let id = Self.assetID(wire, prefix: "image:") {
            self = .image(id)
        } else if let id = Self.assetID(wire, prefix: "svg:") {
            self = .svg(id)
        } else if wire.hasPrefix("image:") || wire.hasPrefix("svg:") {
            return nil
        } else if Self.isEmoji(wire) {
            self = .emoji(wire)
        } else if Self.isSymbolName(wire) {
            self = .symbol(wire)
        } else {
            return nil
        }
    }

    /// The wire string.
    public var wire: String {
        switch self {
        case .emoji(let text): text
        case .symbol(let name): name
        case .image(let id): "image:" + id
        case .svg(let id): "svg:" + id
        }
    }

    /// One emoji grapheme: a presentation emoji, or a sequence (flag, keycap,
    /// skin tone, ZWJ family, a text-default emoji with U+FE0F).
    public static func isEmoji(_ text: String) -> Bool {
        guard text.count == 1, text.utf8.count <= maxEmojiBytes, let first = text.unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        // A text-default base needs more: U+FE0F, a keycap mark or a ZWJ sequence.
        return text.unicodeScalars.count > 1 && first.properties.isEmoji
    }

    /// An SF Symbol name as the daemon stores it: lowercase words of letters
    /// and digits joined by single dots.
    public static func isSymbolName(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maxSymbolBytes, !text.hasPrefix("."), !text.hasSuffix("."),
              !text.contains("..") else { return false }
        return text.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }
    }

    /// `sha256-<64 lowercase hex>`.
    public static func isAssetID(_ text: String) -> Bool {
        let digest = text.utf8.dropFirst(7)
        return text.hasPrefix("sha256-") && digest.count == 64
            && digest.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func assetID(_ wire: String, prefix: String) -> String? {
        guard wire.hasPrefix(prefix) else { return nil }
        let id = String(wire.dropFirst(prefix.count))
        return isAssetID(id) ? id : nil
    }
}
