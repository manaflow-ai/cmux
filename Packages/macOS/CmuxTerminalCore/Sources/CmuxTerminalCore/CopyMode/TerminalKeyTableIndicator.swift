import Foundation

/// The classification of a Ghostty key-table name for the status indicator.
///
/// The terminal status indicator shows which key table (input mode) is active.
/// `TerminalKeyTableIndicator` is the pure, locale-independent classification of
/// a raw key-table name; the app maps each case to a localized label, keeping
/// `String(localized:)` resolution in the app bundle where the catalog keys
/// live.
///
/// Classification preserves the legacy `terminalKeyTableIndicatorText` rules
/// exactly: an empty name or the literal `set` is the default key-table label;
/// `vi`/`vim` is the copy-mode label; anything else is shown verbatim after
/// replacing `_` and `-` with spaces and trimming, falling back to the default
/// label only when that normalization leaves an empty string.
public enum TerminalKeyTableIndicator: Equatable, Sendable {
    /// The generic key-table state (empty name, or the literal `set`, or a name
    /// that normalizes to empty).
    case keyTableDefault

    /// The vim copy-mode state (`vi`/`vim`).
    case copyMode

    /// A named key table shown verbatim after `_`/`-` are replaced with spaces
    /// and the result is trimmed.
    ///
    /// - Parameter displayName: The normalized, non-empty key-table name.
    case custom(displayName: String)

    /// Classifies a raw Ghostty key-table name.
    ///
    /// - Parameter name: The raw key-table name reported by the runtime.
    /// - Returns: The indicator classification for `name`.
    public init(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "", "set":
            self = .keyTableDefault
        case "vi", "vim":
            self = .copyMode
        default:
            let normalized = trimmed
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self = normalized.isEmpty ? .keyTableDefault : .custom(displayName: normalized)
        }
    }
}
