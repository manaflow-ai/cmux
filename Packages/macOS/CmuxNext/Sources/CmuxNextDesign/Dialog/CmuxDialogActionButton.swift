public import SwiftUI

/// A SwiftUI dialog or sheet button that shows the key pressing it and binds that key
/// (u2647): the SwiftUI twin of ``CmuxDialogButtonView``. Return presses the
/// `.return` button (`.defaultAction`), Escape the `.escape` one (`.cancelAction`),
/// Command plus the character a `.command` one.
///
/// ```swift
/// HStack {
///     CmuxDialogActionButton(BookmarkStrings.cancel, hint: .escape) { dismiss() }
///     CmuxDialogActionButton(BookmarkStrings.save, hint: .return) { save() }
/// }
/// ```
public struct CmuxDialogActionButton: View {
    let title: String
    let hint: CmuxDialogKeyHint?
    let role: ButtonRole?
    let action: () -> Void

    /// - Parameters:
    ///   - title: The button's localized title.
    ///   - hint: The key that presses it; nil binds and shows none (a button no key presses).
    ///   - role: The SwiftUI role (`.destructive` draws it in the danger color).
    ///   - action: Runs on a click or the key.
    public init(_ title: String, hint: CmuxDialogKeyHint?, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: Metrics.space2) {
                Text(title)
                if let hint {
                    Text(hint.glyph)
                        .font(Font(Typography.caption))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .keyboardShortcut(hint.map(Self.shortcut))
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(hint?.spokenName ?? ""))
    }

    static func shortcut(_ hint: CmuxDialogKeyHint) -> KeyboardShortcut {
        switch hint {
        case .return: .defaultAction
        case .escape: .cancelAction
        case .command(let character): KeyboardShortcut(KeyEquivalent(character), modifiers: .command)
        }
    }
}
