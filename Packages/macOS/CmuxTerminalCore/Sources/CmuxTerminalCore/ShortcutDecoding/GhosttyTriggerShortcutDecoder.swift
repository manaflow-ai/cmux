/// Decodes a Ghostty key trigger into the shortcut cmux stores for its goto-split
/// menu syncing.
///
/// This owns the byte-identical logic that used to live in
/// `AppDelegate.storedShortcutFromGhosttyTrigger`: choose the key glyph from the
/// trigger tag, reject catch-all and unmapped keys, lowercase a Unicode-scalar key,
/// and reject bogus triggers that carry no key or no modifier. The app target
/// supplies a `GhosttyTriggerInput` (already lifted off the C `ghostty_input_trigger_s`)
/// and maps the returned value onto its own `StoredShortcut`.
public struct GhosttyTriggerShortcutDecoder: Sendable {
    /// Creates a decoder. The decoder is stateless; the type exists so the logic is
    /// owned by a value rather than a free function.
    public init() {}

    /// Decodes a trigger into a stored shortcut, or `nil` when the trigger cannot be
    /// mapped to one.
    ///
    /// Returns `nil` for a catch-all trigger, an unmapped physical key, an invalid
    /// Unicode scalar, an empty key, or a trigger with no Command/Shift/Option/Control
    /// modifier set, exactly as the original implementation did.
    /// - Parameter input: The lifted Ghostty trigger.
    /// - Returns: The decoded shortcut, or `nil`.
    public func decode(_ input: GhosttyTriggerInput) -> GhosttyTriggerShortcut? {
        let key: String
        switch input.tag {
        case let .physical(physicalKey):
            guard let physicalKey else { return nil }
            key = physicalKey.glyph
        case let .unicode(scalar):
            guard let scalar else { return nil }
            key = String(Character(scalar)).lowercased()
        case .catchAll:
            return nil
        }

        let modifiers = input.modifiers
        let command = modifiers.command
        let shift = modifiers.shift
        let option = modifiers.option
        let control = modifiers.control

        // Ignore bogus empty triggers.
        if key.isEmpty || modifiers.isEmpty {
            return nil
        }

        return GhosttyTriggerShortcut(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }
}
