public import GhosttyKit

extension GhosttyTriggerShortcut {
    /// Decodes a GhosttyKit C key trigger (`ghostty_input_trigger_s`) into the
    /// shortcut cmux stores for its goto-split menu syncing, or `nil` when the
    /// trigger cannot be mapped.
    ///
    /// This is the GhosttyKit-boundary half of the conversion that used to live in
    /// `AppDelegate.storedShortcutFromGhosttyTrigger`: switch on the trigger tag
    /// (`GHOSTTY_TRIGGER_PHYSICAL`/`GHOSTTY_TRIGGER_UNICODE`/`GHOSTTY_TRIGGER_CATCH_ALL`),
    /// lift the key payload and the raw modifier bitmask off the C struct into a
    /// ``GhosttyTriggerInput``, and feed it through ``init(decoding:)``. CmuxTerminalCore
    /// re-vends the GhosttyKit binary target, so the C symbols are visible here
    /// alongside the value types, keeping the C-struct decode in the owning package
    /// while the app target maps the result onto its own `StoredShortcut` at the call
    /// seam. Returns `nil` for any trigger tag cmux does not map (matching the
    /// original switch's `default` branch) and for every case ``init(decoding:)``
    /// rejects.
    /// - Parameter trigger: The raw Ghostty trigger returned by `ghostty_config_trigger`.
    public init?(ghosttyConfigTrigger trigger: ghostty_input_trigger_s) {
        let tag: GhosttyTriggerInput.Tag
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

        let input = GhosttyTriggerInput(
            tag: tag,
            modifiers: GhosttyModifierMask(rawValue: trigger.mods.rawValue)
        )
        self.init(decoding: input)
    }
}
