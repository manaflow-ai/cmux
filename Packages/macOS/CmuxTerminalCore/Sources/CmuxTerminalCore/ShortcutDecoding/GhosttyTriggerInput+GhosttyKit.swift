public import GhosttyKit

extension GhosttyTriggerInput {
    /// Packs a GhosttyKit C key trigger (`ghostty_input_trigger_s`) into the
    /// Sendable ``GhosttyTriggerInput`` value, or `nil` for a trigger whose tag
    /// cmux does not handle.
    ///
    /// This is the GhosttyKit-boundary lift that used to live inline in
    /// `AppDelegate.storedShortcutFromGhosttyTrigger`: read the C trigger tag,
    /// map `GHOSTTY_TRIGGER_PHYSICAL`/`GHOSTTY_TRIGGER_UNICODE`/
    /// `GHOSTTY_TRIGGER_CATCH_ALL` onto a ``GhosttyTriggerInput/Tag`` (a physical
    /// key via ``GhosttyTriggerPhysicalKey/init(ghosttyPhysicalKey:)``, a Unicode
    /// scalar via `UnicodeScalar(_:)`, or the catch-all case), and carry the raw
    /// `mods.rawValue` bitmask through ``GhosttyModifierMask``. Returns `nil` for
    /// any trigger tag outside those three, matching the original switch's
    /// `default` branch.
    ///
    /// Expressed as a failable initializer on the owning value type so it mirrors
    /// ``GhosttyTriggerPhysicalKey/init(ghosttyPhysicalKey:)``, the sibling
    /// trigger-to-value conversion, and keeps the GhosttyKit dependency on the one
    /// value that wraps a C trigger. CmuxTerminalCore re-vends the GhosttyKit
    /// binary target, so the C symbols are visible here. The app target reads the
    /// raw C trigger from `ghostty_config_trigger`, builds this value, decodes it
    /// with ``GhosttyTriggerShortcut/init(decoding:)``, and maps the result onto
    /// its own `StoredShortcut` at the call seam.
    /// - Parameter trigger: The raw GhosttyKit key trigger.
    public init?(decoding trigger: ghostty_input_trigger_s) {
        let tag: Tag
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            tag = .physical(GhosttyTriggerPhysicalKey(ghosttyPhysicalKey: trigger.key.physical))
        case GHOSTTY_TRIGGER_UNICODE:
            tag = .unicode(UnicodeScalar(trigger.key.unicode))
        case GHOSTTY_TRIGGER_CATCH_ALL:
            tag = .catchAll
        default:
            return nil
        }

        self.init(
            tag: tag,
            modifiers: GhosttyModifierMask(rawValue: trigger.mods.rawValue)
        )
    }
}
