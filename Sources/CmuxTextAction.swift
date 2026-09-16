import Foundation

/// Literal text delivered to the focused terminal by a `type: "text"` action.
///
/// Unlike `type: "command"`, the text is pasted (bracketed paste when the
/// application enables it) and is **not** submitted unless `submit` is true,
/// so multi-line prompts land in an agent composer or shell line editor
/// verbatim. This is the primitive an iTerm2-style Snippets feature builds on.
struct CmuxTextActionPayload: Codable, Sendable, Hashable {
    /// Named key pressed after the paste when `submit` is true.
    static let submitKeyName = "enter"
    /// Upper bound on the generated identifier slug so huge snippets do not
    /// produce unwieldy action ids.
    static let identifierSlugMaxLength = 40

    var text: String
    var submit: Bool

    init(text: String, submit: Bool = false) {
        self.text = text
        self.submit = submit
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case submit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .text)
        guard let sanitized = Self.sanitizedText(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "text actions require non-blank text"
            )
        }
        text = sanitized
        submit = try container.decodeIfPresent(Bool.self, forKey: .submit) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if submit {
            try container.encode(submit, forKey: .submit)
        }
    }

    /// Ordered input steps that realise this payload on a terminal panel.
    var deliverySteps: [CmuxTextActionDeliveryStep] {
        var steps: [CmuxTextActionDeliveryStep] = [.pasteText(text)]
        if submit {
            steps.append(.namedKey(Self.submitKeyName))
        }
        return steps
    }

    /// Insert-only text cannot run anything, so it skips the project-action
    /// trust prompt. Submitting text is equivalent to running a command and
    /// goes through the same gate as `type: "command"`.
    var requiresProjectTrust: Bool {
        submit
    }

    /// Stable, filesystem-safe component for a generated action id.
    var identifierSlug: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        let bounded = String(encoded.prefix(Self.identifierSlugMaxLength))
        return bounded.isEmpty ? "text" : bounded
    }

    /// Strips bidi and zero-width controls that could disguise what a
    /// project-local config inserts, while preserving newlines and
    /// indentation. Returns nil when nothing meaningful remains.
    static func sanitizedText(_ raw: String) -> String? {
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
enum CmuxTextActionDeliveryStep: Sendable, Hashable {
    case pasteText(String)
    case namedKey(String)
}
