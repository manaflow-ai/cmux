/// A Sendable description of a Ghostty key trigger, decoupled from GhosttyKit's C
/// `ghostty_input_trigger_s` struct.
///
/// The app target reads the raw C trigger returned by `ghostty_config_trigger` and
/// packs the parts cmux cares about into this value at the call seam, so
/// `GhosttyTriggerShortcut(decoding:)` can decode it with no GhosttyKit dependency.
public struct GhosttyTriggerInput: Sendable, Equatable, Hashable {
    /// The kind of trigger Ghostty resolved the binding to.
    public enum Tag: Sendable, Equatable, Hashable {
        /// A trigger keyed by a physical key (`GHOSTTY_TRIGGER_PHYSICAL`).
        ///
        /// The associated value is `nil` when the physical key is one cmux does not
        /// render as a shortcut, matching the original switch's `default` branch.
        case physical(GhosttyTriggerPhysicalKey?)
        /// A trigger keyed by a Unicode scalar (`GHOSTTY_TRIGGER_UNICODE`).
        ///
        /// The associated value is `nil` when the raw codepoint is not a valid
        /// Unicode scalar, matching the original `UnicodeScalar(...)` guard.
        case unicode(Unicode.Scalar?)
        /// A catch-all trigger (`GHOSTTY_TRIGGER_CATCH_ALL`), which never yields a
        /// shortcut.
        case catchAll
    }

    /// The resolved trigger tag and its key payload.
    public var tag: Tag
    /// The raw Ghostty modifier bitmask (`ghostty_input_trigger_s.mods.rawValue`).
    public var modifiers: GhosttyModifierMask

    /// Creates a trigger input from a tag and a raw Ghostty modifier bitmask.
    /// - Parameters:
    ///   - tag: The resolved trigger tag and key payload.
    ///   - modifiers: The raw Ghostty modifier bitmask carried by the trigger.
    public init(tag: Tag, modifiers: GhosttyModifierMask) {
        self.tag = tag
        self.modifiers = modifiers
    }
}
