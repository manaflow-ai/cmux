import Foundation
public import CmuxSettings

/// The `cmd+shift+x` config grammar for a whole ``StoredShortcut`` binding.
///
/// ## Why this lives here
///
/// A binding is encoded in `cmux.json` as either a single token string, a
/// one-or-two-element array of stroke tokens (a chord), or an explicit
/// "unbound" sentinel (`""`/`none`/`clear`/`unbound`/`disabled`). Decoding that
/// shape into a ``StoredShortcut`` (and rendering ``configIdentifier`` back) is
/// pure string work on top of the per-stroke grammar in
/// ``ShortcutStroke/parseConfig(_:)``, so it sits in the same shortcut-decode
/// layer rather than on the app's settings god object.
///
/// The grammar is byte-identical to the legacy app-target implementation:
/// the same unbound tokens, the same one-or-two-stroke arity rule, the same
/// "bare first stroke needs a modifier (or is the space key) unless the action
/// opts in" rule, and the same ``configIdentifier`` rendering (`"none"` when
/// unbound, space-joined stroke tokens otherwise). Changing any token here is a
/// wire-format change to every user's `cmux.json`.
extension StoredShortcut {
    /// Parses a single config token (string form) into a ``StoredShortcut``.
    ///
    /// An unbound token (`""`, `none`, `clear`, `unbound`, `disabled`, or
    /// whitespace) yields ``StoredShortcut/unbound``. Otherwise the token is
    /// parsed as a one-stroke binding. `allowBareFirstStroke` lets an action
    /// permit a first stroke with no modifier (most actions require one).
    public static func parseConfig(
        _ rawValue: String,
        allowBareFirstStroke: Bool = false
    ) -> StoredShortcut? {
        if isUnboundConfigToken(rawValue) {
            return .unbound
        }
        return parseConfig(strokes: [rawValue], allowBareFirstStroke: allowBareFirstStroke)
    }

    /// Parses an array of one or two stroke tokens (chord form) into a
    /// ``StoredShortcut``, or `nil` when the arity is wrong, any stroke fails to
    /// parse, or a bare first stroke is used by an action that requires a
    /// modifier.
    ///
    /// A single-element array whose sole token is an unbound sentinel yields
    /// ``StoredShortcut/unbound``.
    public static func parseConfig(
        strokes: [String],
        allowBareFirstStroke: Bool = false
    ) -> StoredShortcut? {
        guard !strokes.isEmpty, strokes.count <= 2 else { return nil }
        if strokes.count == 1, let rawValue = strokes.first, isUnboundConfigToken(rawValue) {
            return .unbound
        }
        let parsedStrokes = strokes.compactMap(ShortcutStroke.parseConfig(_:))
        guard parsedStrokes.count == strokes.count, let firstStroke = parsedStrokes.first else {
            return nil
        }
        guard allowBareFirstStroke || firstStroke.hasAnyModifier || firstStroke.key == "space" else {
            return nil
        }
        let secondStroke = parsedStrokes.count == 2 ? parsedStrokes[1] : nil
        return StoredShortcut(first: firstStroke, second: secondStroke)
    }

    /// The canonical config token(s) for this binding: `"none"` when unbound,
    /// the single stroke token when single-stroke, or the two stroke tokens
    /// joined by a space when chorded.
    public var configIdentifier: String {
        if isUnbound { return "none" }
        if let second {
            return "\(first.configString()) \(second.configString())"
        }
        return first.configString()
    }

    /// True when a raw config token means "explicitly unbound": empty,
    /// whitespace-only, or one of `none`/`clear`/`unbound`/`disabled`
    /// (case-insensitive). A literal single space is NOT unbound (it is the
    /// space key).
    private static func isUnboundConfigToken(_ rawValue: String) -> Bool {
        if rawValue.isEmpty { return true }
        if rawValue == " " { return false }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized == "none" || normalized == "clear" || normalized == "unbound" || normalized == "disabled"
    }
}
