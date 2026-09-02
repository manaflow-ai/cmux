import Foundation

/// Bounds and cleans notification text that arrives from an untrusted emitter (a cloud
/// machine's daemon stream) before it reaches the notification store — and through it
/// the banner, the sidebar, the feed history, hook environments, `notifications.command`,
/// and a paired phone. Local `cmux notify` callers are trusted and keep their text as is.
///
/// Rules, in order: NFC-normalize; strip ANSI/CSI/OSC escape sequences (a hook that
/// echoes a field to a tty must not be steerable by the emitter); neutralize every control
/// character, line break, and paragraph separator into a space (single-line for logs,
/// shell consumers, and banner layout); drop bidi overrides and invisible format characters
/// that can spoof the banner ("run: safe…" rendered backwards); collapse whitespace; trim;
/// then truncate to `maxBytes` of UTF-8 on a `Character` boundary with an ellipsis.
enum NotificationTextSanitizer {
    /// The alternation the mobile preview uses (`TerminalController+MobileWorkspaceList`):
    /// CSI with the full ECMA-48 parameter range, OSC up to BEL/ST/end-of-input, and the
    /// remaining two-byte ESC sequences — plus their 8-bit C1 forms (U+009B CSI, U+009D OSC,
    /// U+009C ST), which some terminals dispatch even in UTF-8 mode. Unterminated sequences
    /// at end of input match too, so a sequence cut by a cap is stripped rather than leaking
    /// its payload.
    static let escapeSequencePattern =
        "\u{001B}\\[[0-9:;<=>?]*[ -/]*[@-~]?"
        + "|\u{001B}\\][^\u{0007}\u{001B}\u{009C}]*(?:\u{0007}|\u{001B}\\\\|\u{009C}|$)"
        + "|\u{001B}[@-Z\\\\-_]"
        + "|\u{009B}[0-9:;<=>?]*[ -/]*[@-~]?"
        + "|\u{009D}[^\u{0007}\u{001B}\u{009C}]*(?:\u{0007}|\u{001B}\\\\|\u{009C}|$)"

    /// Bidi controls and invisible format characters removed outright. ZWJ/ZWNJ stay:
    /// they are part of emoji sequences and of scripts that need them.
    private static let droppedScalars: Set<UInt32> = {
        var set = Set<UInt32>()
        set.formUnion(0x202A...0x202E) // LRE, RLE, PDF, LRO, RLO
        set.formUnion(0x2066...0x2069) // LRI, RLI, FSI, PDI
        set.insert(0x200E)             // LRM
        set.insert(0x200F)             // RLM
        set.insert(0x061C)             // ALM
        set.insert(0x200B)             // ZWSP
        set.formUnion(0x2060...0x2064) // WJ, invisible operators
        set.insert(0xFEFF)             // BOM / ZWNBSP
        return set
    }()

    static func sanitize(_ text: String, maxBytes: Int) -> String {
        guard !text.isEmpty else { return "" }
        let normalized = text.precomposedStringWithCanonicalMapping
        let withoutEscapes = normalized.replacingOccurrences(
            of: escapeSequencePattern,
            with: "",
            options: .regularExpression
        )
        var scalars = String.UnicodeScalarView()
        for scalar in withoutEscapes.unicodeScalars {
            if droppedScalars.contains(scalar.value) {
                continue
            }
            if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
                || scalar.value == 0x2028 || scalar.value == 0x2029
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return truncate(collapsed, maxBytes: maxBytes)
    }

    /// Cuts on a `Character` boundary so a multi-byte grapheme at the cap is never split,
    /// and marks the cut with an ellipsis that fits inside the cap.
    static func truncate(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        let ellipsis = "\u{2026}"
        let budget = max(0, maxBytes - ellipsis.utf8.count)
        var used = 0
        var prefix = ""
        for character in text {
            let width = character.utf8.count
            guard used + width <= budget else { break }
            prefix.append(character)
            used += width
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        return trimmed + ellipsis
    }
}
