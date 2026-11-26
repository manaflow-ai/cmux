/// A keyboard shortcut decoded from a Ghostty key trigger.
///
/// Carries exactly the fields the app target feeds into its `StoredShortcut`
/// initializer from the Ghostty goto-split path: a lowercased key string and the
/// four modifier flags. The app maps this value onto its own `StoredShortcut` at
/// the call seam.
public struct GhosttyTriggerShortcut: Sendable, Equatable, Hashable {
    /// The key glyph or lowercased character for the shortcut.
    public var key: String
    /// Whether the Command modifier is part of the shortcut.
    public var command: Bool
    /// Whether the Shift modifier is part of the shortcut.
    public var shift: Bool
    /// Whether the Option modifier is part of the shortcut.
    public var option: Bool
    /// Whether the Control modifier is part of the shortcut.
    public var control: Bool

    /// Creates a decoded shortcut.
    /// - Parameters:
    ///   - key: The key glyph or lowercased character.
    ///   - command: Whether Command is held.
    ///   - shift: Whether Shift is held.
    ///   - option: Whether Option is held.
    ///   - control: Whether Control is held.
    public init(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Decodes a Ghostty key trigger into the shortcut cmux stores for its
    /// goto-split menu syncing, or `nil` when the trigger cannot be mapped.
    ///
    /// This is the value-owned conversion that used to live in
    /// `AppDelegate.storedShortcutFromGhosttyTrigger`: choose the key glyph from
    /// the trigger tag, reject catch-all and unmapped keys, lowercase a
    /// Unicode-scalar key, and reject bogus triggers that carry no key or no
    /// modifier. Expressed as a failable initializer on the owning type so it
    /// mirrors `GhosttyTriggerPhysicalKey.init?(ghosttyPhysicalKey:)`, the sibling
    /// trigger-to-value conversion, rather than living on a separate stateless
    /// decoder type. The app target supplies a ``GhosttyTriggerInput`` (already
    /// lifted off the C `ghostty_input_trigger_s`) and maps the result onto its own
    /// `StoredShortcut`.
    ///
    /// Returns `nil` for a catch-all trigger, an unmapped physical key, an invalid
    /// Unicode scalar, an empty key, or a trigger with no Command/Shift/Option/Control
    /// modifier set, exactly as the original implementation did.
    /// - Parameter input: The lifted Ghostty trigger.
    public init?(decoding input: GhosttyTriggerInput) {
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

        // Ignore bogus empty triggers.
        if key.isEmpty || modifiers.isEmpty {
            return nil
        }

        self.init(
            key: key,
            command: modifiers.command,
            shift: modifiers.shift,
            option: modifiers.option,
            control: modifiers.control
        )
    }
}
