import Foundation

/// The action-independent grammar for the optional cmux leader key.
///
/// A prefix is deliberately narrower than an ordinary shortcut binding: it is
/// exactly one key event, must be observable by the foreground AppKit monitor,
/// and must not be a bare printable key that would make ordinary terminal
/// typing arm the layer accidentally. Keeping this policy in the shared
/// settings package prevents the JSON store, Settings recorder, and runtime
/// router from accepting different representations.
public enum ShortcutPrefixPolicyResult: Sendable, Equatable {
    /// The value is a supported, single-stroke prefix.
    case accepted
    /// The value explicitly disables the prefix layer.
    case unbound
    /// The value contains more than one stroke.
    case singleStrokeRequired
    /// A non-unbound value has no first key to identify its prefix stroke.
    case emptyStrokeNotSupported
    /// The stroke is a printable key without a modifier (other than Space).
    case modifierRequired
    /// The stroke is a media/system-defined key that AppKit cannot route safely.
    case systemDefinedKeyNotSupported
    /// Escape is reserved for cancelling an armed prefix.
    case escapeReserved
}

/// Validates and canonicalizes the optional leader key shared by settings and runtime routing.
///
/// The policy is a value type so callers can inject it into tests or a future
/// host with different platform constraints without relying on a namespace
/// enum or global mutable state.
public struct ShortcutPrefixPolicy: Sendable {
    /// Creates the default prefix policy.
    public init() {}

    /// Validates a persisted prefix value.
    public func result(for shortcut: StoredShortcut) -> ShortcutPrefixPolicyResult {
        if shortcut.isUnbound { return .unbound }
        // `StoredShortcut.unbound` is the only valid empty-first-stroke value.
        // An empty first stroke paired with a suffix is malformed and must not
        // be normalized into a disabled prefix or accepted as a chord.
        guard !shortcut.first.canonicalized().key.isEmpty else {
            return .emptyStrokeNotSupported
        }
        guard !shortcut.hasChord else { return .singleStrokeRequired }

        let stroke = shortcut.first.canonicalized()
        if Self.isSystemDefinedKey(stroke.key) {
            return .systemDefinedKeyNotSupported
        }
        if stroke.key.lowercased() == "escape" || stroke.key == "\u{1b}" {
            return .escapeReserved
        }
        guard stroke.hasAnyModifier || stroke.key == "space" else {
            return .modifierRequired
        }
        return .accepted
    }

    /// Returns the canonical persisted value when `shortcut` is a valid
    /// prefix, or `nil` for malformed/unsupported values. The explicit
    /// unbound marker is preserved as a valid disabled value.
    public func normalized(_ shortcut: StoredShortcut) -> StoredShortcut? {
        switch result(for: shortcut) {
        case .accepted:
            return StoredShortcut(first: shortcut.first.canonicalized())
        case .unbound:
            return .unbound
        case .singleStrokeRequired, .emptyStrokeNotSupported, .modifierRequired,
             .systemDefinedKeyNotSupported, .escapeReserved:
            return nil
        }
    }

    /// Convenience form for Settings recorders and event adapters.
    public func normalized(_ stroke: ShortcutStroke) -> ShortcutStroke? {
        // `.unbound` is a valid persisted value, but it is not a usable
        // runtime stroke.  Returning its empty first stroke here would make a
        // disabled prefix look configured to event routers.
        guard result(for: StoredShortcut(first: stroke)) == .accepted else {
            return nil
        }
        return stroke.canonicalized()
    }

    private static func isSystemDefinedKey(_ key: String) -> Bool {
        let token = key.lowercased().replacingOccurrences(of: ".", with: "")
        switch token {
        case "volumeup", "mediavolumeup",
             "volumedown", "mediavolumedown",
             "brightnessup", "mediabrightnessup",
             "brightnessdown", "mediabrightnessdown",
             "mute", "mediamute",
             "playpause", "mediaplaypause",
             "nexttrack", "medianext", "medianexttrack",
             "previoustrack", "mediaprevious", "mediaprevioustrack":
            return true
        default:
            return token.hasPrefix("media")
        }
    }
}
