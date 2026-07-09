import SwiftUI

/// A menu/command `Button` that optionally carries a keyboard-shortcut
/// equivalent, used to render shortcut-bound commands in the app's main menu.
///
/// The shortcut is supplied as already-bridged SwiftUI values rather than a
/// `StoredShortcut`, because the `StoredShortcut` → SwiftUI bridge
/// (`keyEquivalent`/`eventModifiers`) lives in the app target, above this
/// package in the dependency graph. Callers evaluate that bridge and pass the
/// resulting `KeyEquivalent?` and `EventModifiers` here. When `keyEquivalent`
/// is `nil` (an unbound or chorded binding) the button renders with no
/// `.keyboardShortcut`, matching the legacy `splitCommandButton` behavior
/// byte-for-byte.
public struct ShortcutCommandButton: View {
    private let title: String
    private let keyEquivalent: KeyEquivalent?
    private let eventModifiers: EventModifiers
    private let action: () -> Void

    /// Creates a shortcut-bound command button.
    /// - Parameters:
    ///   - title: The button's label.
    ///   - keyEquivalent: The bridged key equivalent, or `nil` to render the
    ///     button without a keyboard shortcut.
    ///   - eventModifiers: The bridged modifier flags applied when
    ///     `keyEquivalent` is non-`nil`.
    ///   - action: The action invoked when the button is triggered.
    public init(
        title: String,
        keyEquivalent: KeyEquivalent?,
        eventModifiers: EventModifiers,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.eventModifiers = eventModifiers
        self.action = action
    }

    public var body: some View {
        if let keyEquivalent {
            Button(title, action: action)
                .keyboardShortcut(keyEquivalent, modifiers: eventModifiers)
        } else {
            Button(title, action: action)
        }
    }
}
