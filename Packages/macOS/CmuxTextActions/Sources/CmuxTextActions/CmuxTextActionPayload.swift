import Foundation

/// Literal text delivered to the focused terminal by a `type: "text"` action.
///
/// Unlike `type: "command"`, the text is pasted (bracketed paste when the
/// application enables it) and is **not** submitted unless `submit` is true,
/// so multi-line prompts land in an agent composer or shell line editor
/// verbatim. This is the primitive an iTerm2-style Snippets feature builds on.
public struct CmuxTextActionPayload: Codable, Sendable, Hashable {
    /// Named key pressed after the paste when `submit` is true.
    public static let submitKeyName = "enter"
    /// Upper bound on the generated identifier slug so huge snippets do not
    /// produce unwieldy action ids.
    public static let identifierSlugMaxLength = 40
    /// Hex digits of the payload digest that ends every slug.
    static let identifierDigestLength = 16
    /// Readable text kept in front of the digest: the slug bound minus the
    /// separator and the digest.
    static let identifierPrefixMaxLength = identifierSlugMaxLength - 1 - identifierDigestLength

    /// Sanitised, non-blank text. Only the validating initializer can set it.
    public let text: String
    /// Whether delivery presses Enter after pasting the text.
    public let submit: Bool

    /// Validating initializer: strips bidi and zero-width controls and
    /// returns nil when nothing meaningful remains, so a blank or disguised
    /// payload is unrepresentable anywhere in the module.
    ///
    /// - Parameters:
    ///   - rawText: Text to paste, with newlines and indentation preserved.
    ///   - submit: Whether to press Enter after pasting. Defaults to false.
    public init?(text rawText: String, submit: Bool = false) {
        guard let sanitized = Self.sanitizedText(rawText) else { return nil }
        self.text = sanitized
        self.submit = submit
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case submit
    }

    /// Decodes `text` (required, validated) and `submit` (default false).
    ///
    /// - Parameter decoder: Decoder containing the action payload.
    /// - Throws: A decoding error for missing, invalid, or blank text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .text)
        let submit = try container.decodeIfPresent(Bool.self, forKey: .submit) ?? false
        guard let payload = CmuxTextActionPayload(text: raw, submit: submit) else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "text actions require non-blank text"
            )
        }
        self = payload
    }

    /// Encodes `text` and, only when true, `submit`.
    ///
    /// - Parameter encoder: Encoder receiving the action payload.
    /// - Throws: Any error reported by the encoder.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if submit {
            try container.encode(submit, forKey: .submit)
        }
    }

    /// Ordered input steps that realise this payload on a terminal panel.
    public var deliverySteps: [CmuxTextActionDeliveryStep] {
        var steps: [CmuxTextActionDeliveryStep] = [.pasteText(text)]
        if submit {
            steps.append(.namedKey(Self.submitKeyName))
        }
        return steps
    }

    /// Stable, filesystem-safe component for a generated action id: a
    /// readable prefix of the percent-encoded text followed by a digest of
    /// the whole payload, so two snippets that share a prefix, or the same
    /// text with and without `submit`, never collapse onto one id.
    public var identifierSlug: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        let prefix = String(encoded.prefix(Self.identifierPrefixMaxLength))
        return (prefix.isEmpty ? "text" : prefix) + "-" + payloadDigest
    }

    /// FNV-1a (64-bit) over the UTF-8 text, a separator, and the submit
    /// flag. Unlike `Hasher` it is stable across launches, and it needs no
    /// CryptoKit, keeping this module Foundation-only.
    var payloadDigest: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        for byte in text.utf8 {
            mix(byte)
        }
        mix(0)
        mix(submit ? 1 : 0)
        return String(format: "%0\(Self.identifierDigestLength)llx", hash)
    }

    /// Strips bidi and zero-width controls that could disguise what a
    /// project-local config inserts, while preserving newlines and
    /// indentation. Returns nil when nothing meaningful remains.
    ///
    /// - Parameter raw: The unsanitized snippet text.
    /// - Returns: Sanitized text, or nil for an empty or whitespace-only payload.
    public static func sanitizedText(_ raw: String) -> String? {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}"
        ]
        let filtered = String(raw.unicodeScalars.filter { !dangerous.contains($0) })
        guard !filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return filtered
    }
}
