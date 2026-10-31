/// The dialog keyboard as a pure function, so every dialog answers keys the
/// same way: Return presses the default button, Escape (or Command-period)
/// the cancel button, Command plus a button's `key` that button, Tab and
/// Shift-Tab move focus inside the dialog only (the focus trap).
public nonisolated struct CmuxDialogKeys {
    public nonisolated init() {}
    public enum Key: Equatable, Sendable {
        case `return`
        case escape
        case tab
        case character(Character)
    }

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public enum Action: Equatable, Sendable {
        case press(String)
        case focusNext
        case focusPrevious
    }

    /// The action for one key press in a dialog showing `spec`; nil lets
    /// the key reach the focused control (typing in a field).
    public static func action(for key: Key, modifiers: Modifiers, in spec: CmuxDialogSpec) -> Action? {
        guard let action = keyAction(for: key, modifiers: modifiers, in: spec) else { return nil }
        // A click-only button takes no key; the key does nothing rather than reach another control.
        if case .press(let id) = action, spec.buttons.first(where: { $0.id == id })?.clickOnly == true { return nil }
        return action
    }

    private static func keyAction(for key: Key, modifiers: Modifiers, in spec: CmuxDialogSpec) -> Action? {
        let others = modifiers.subtracting(.shift)
        switch key {
        case .return:
            guard others.isEmpty || others == .command else { return nil }
            return spec.defaultButton.map { .press($0.id) }
        case .escape:
            return spec.cancelButton.map { .press($0.id) }
        case .tab:
            guard others.isEmpty else { return nil }
            return modifiers.contains(.shift) ? .focusPrevious : .focusNext
        case .character(let character):
            guard others == .command else { return nil }
            if character == "." { return spec.cancelButton.map { .press($0.id) } }
            let lowered = Character(character.lowercased())
            return spec.buttons.first { $0.key == lowered }.map { .press($0.id) }
        }
    }

    /// The key that presses `button` in a dialog showing `spec`, the inverse of
    /// ``action(for:modifiers:in:)``: Return for the default button, Escape for the
    /// cancel button, else Command plus the button's `key`; nil when no key presses it.
    public static func hint(for button: CmuxDialogButton, in spec: CmuxDialogSpec) -> CmuxDialogKeyHint? {
        if button.clickOnly { return nil }
        if spec.defaultButton?.id == button.id { return .return }
        if spec.cancelButton?.id == button.id { return .escape }
        guard let key = button.key, spec.buttons.first(where: { $0.key == key })?.id == button.id else { return nil }
        return .command(key)
    }

    /// The control after (or before) `current` among `count` controls,
    /// wrapping at both ends; with none focused, the first (or last).
    public static func focus(after current: Int?, count: Int, backward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return backward ? count - 1 : 0 }
        return backward ? (current + count - 1) % count : (current + 1) % count
    }
}
