public import Foundation

/// The icon acpmux resolved for one harness (`iconSpec` on each `_acpmux/harnesses` entry,
/// `cmux-tui/crates/acpmux/src/config/harness_icon.rs`; user 12922).
///
/// Every surface draws this one answer: the tab strip, the sidebar's rows and the pages. A
/// profile's own icon (``isOwn``) wins over the mark its harness id suggests.
///
/// ```swift
/// let spec = HarnessIconSpec(json: ["kind": "emoji", "text": "🦊", "source": "profile"])
/// spec?.isOwn // true
/// ```
public nonisolated enum HarnessIconSpec: Equatable, Sendable {
    /// An agent mark id from design/agent-icons (`claude`, `gemini`).
    case brand(String, isOwn: Bool)
    /// A built-in glyph: `terminal` or `generic`.
    case glyph(String, isOwn: Bool)
    /// One emoji.
    case emoji(String, isOwn: Bool)
    /// An SF Symbol name, with the monogram to show where it cannot be drawn.
    case symbol(String, monogram: String, hue: Int, isOwn: Bool)
    /// A PNG or SVG file's bytes; `mime` is `image/png` or `image/svg+xml`.
    case image(Data, mime: String, isOwn: Bool)
    /// One or two letters on a disc of `hue` (0-359).
    case monogram(String, hue: Int, isOwn: Bool)

    /// The profile set this icon (`source: "profile"`), rather than acpmux picking it.
    public var isOwn: Bool {
        switch self {
        case .brand(_, let own), .glyph(_, let own), .emoji(_, let own), .image(_, _, let own): own
        case .symbol(_, _, _, let own), .monogram(_, _, let own): own
        }
    }

    /// The spec of one `iconSpec` JSON object, or nil when it is malformed.
    /// - Parameter json: The decoded `iconSpec` value.
    public init?(json: Any?) {
        guard let decoded = json as? [String: Any], let kind = decoded["kind"] as? String else { return nil }
        let object: [String: Any] = decoded
        let own = object["source"] as? String == "profile"
        let text = { (key: String, max: Int) -> String? in
            (object[key] as? String).flatMap { $0.isEmpty || $0.utf8.count > max ? nil : $0 }
        }
        let hue = (object["hue"] as? Int).flatMap { (0..<360).contains($0) ? $0 : nil }
        switch kind {
        case "brand":
            guard let brand = text("brand", 64) else { return nil }
            self = .brand(brand, isOwn: own)
        case "glyph":
            guard let name = text("name", 16), ["terminal", "generic"].contains(name) else { return nil }
            self = .glyph(name, isOwn: own)
        case "emoji":
            guard let emoji = text("text", 32) else { return nil }
            self = .emoji(emoji, isOwn: own)
        case "symbol":
            guard let name = text("name", 128), let letters = text("text", 8), let hue else { return nil }
            self = .symbol(name, monogram: letters, hue: hue, isOwn: own)
        case "image":
            guard let mime = text("mime", 32), mime == "image/png" || mime == "image/svg+xml",
                  let encoded = text("data", 400_000), let data = Data(base64Encoded: encoded) else { return nil }
            self = .image(data, mime: mime, isOwn: own)
        case "monogram":
            guard let letters = text("text", 8), let hue else { return nil }
            self = .monogram(letters, hue: hue, isOwn: own)
        default:
            return nil
        }
    }
}
