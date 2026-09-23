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

    /// Sanitised, non-blank text. Only the validating initializer can set it.
    public let text: String
    public let submit: Bool

    /// Validating initializer: strips bidi and zero-width controls and
    /// returns nil when nothing meaningful remains, so a blank or disguised
    /// payload is unrepresentable anywhere in the module.
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

    /// Insert-only text cannot run anything, so it skips the project-action
    /// trust prompt. Submitting text is equivalent to running a command and
    /// goes through the same gate as `type: "command"`.
    public var requiresProjectTrust: Bool {
        submit
    }

    /// Stable, filesystem-safe component for a generated action id.
    public var identifierSlug: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        let bounded = String(encoded.prefix(Self.identifierSlugMaxLength))
        return bounded.isEmpty ? "text" : bounded
    }

    /// Strips bidi and zero-width controls that could disguise what a
    /// project-local config inserts, while preserving newlines and
    /// indentation. Returns nil when nothing meaningful remains.
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

/// One input operation against a terminal panel.
public enum CmuxTextActionDeliveryStep: Sendable, Hashable {
    case pasteText(String)
    case namedKey(String)
}
