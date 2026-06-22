import Foundation

/// How cmux answers Claude Code's compacted-session resume prompt when it
/// auto-resumes a Claude agent on session restore. Claude shows an interactive
/// menu ("Resume from summary" / "Resume full session as-is" / "Don't ask me
/// again") that has no CLI flag or config to skip, so cmux drives it for you.
///   - ``ask`` — leave the prompt for you to answer (current behavior, default).
///   - ``full`` — auto-select "Resume full session as-is".
///   - ``summary`` — auto-select "Resume from summary".
public enum ClaudeResumeMode: String, CaseIterable, Sendable, Identifiable, SettingCodable {
    case ask
    case full
    case summary

    public var id: String { rawValue }

    /// Tolerant parse shared by every configuration surface (`cmux.json`,
    /// `settings.json`, the control socket): trims whitespace and accepts a few
    /// natural spellings case-insensitively.
    public init?(rawString: String?) {
        guard let raw = rawString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // Accept only the exact schema enum values (case-insensitive + trimmed);
        // anything else is rejected so out-of-schema config is reported invalid
        // rather than silently accepted. Keep in sync with
        // web/data/cmux.schema.json (`terminal.claudeResumeMode` enum).
        switch raw.lowercased() {
        case "ask":
            self = .ask
        case "full":
            self = .full
        case "summary":
            self = .summary
        default:
            return nil
        }
    }

    public static func decodeFromUserDefaults(_ raw: Any?) -> ClaudeResumeMode? {
        guard let string = raw as? String else { return nil }
        return ClaudeResumeMode(rawString: string)
    }

    public func encodeForUserDefaults() -> Any { rawValue }

    public static func decodeFromJSON(_ raw: Any?) -> ClaudeResumeMode? {
        guard let string = raw as? String else { return nil }
        return ClaudeResumeMode(rawString: string)
    }

    public func encodeForJSON() -> Any { rawValue }
}
