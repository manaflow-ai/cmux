public import SwiftUI

/// A SwiftUI dialog or sheet button that shows the key pressing it and binds that key
/// (u2647): the SwiftUI twin of ``CmuxDialogButtonView``, drawn in its look (``CmuxDialogButtonStyle``), so it reads
/// as a theme button on any card or popover glass, never AppKit's stock bezel. Return presses the
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
    ///   - hint: The key that presses it; nil binds and shows none (a button no key presses). Return draws the
    ///     accent fill (the default button), Escape and none the theme gray.
    ///   - role: The SwiftUI role (`.destructive` draws it in the danger fill).
    ///   - action: Runs on a click or the key.
    public init(_ title: String, hint: CmuxDialogKeyHint?, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) { Text(title) }
            .buttonStyle(CmuxDialogButtonStyle(CmuxDialogButton(id: title, title: title, role: dialogRole), hint: hint))
            // The look draws its own ring in the theme (3:1 on the card), never the system accent's.
            .focusEffectDisabled()
            .keyboardShortcut(hint.map(Self.shortcut))
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(hint?.spokenName ?? ""))
    }

    /// The look's role: a destructive button the danger fill, the Return button the accent one, Escape's the gray
    /// cancel, any other the gray normal one.
    var dialogRole: CmuxDialogButton.Role {
        if role == .destructive { return .destructive }
        if role == .cancel { return .cancel }
        return switch hint {
        case .return?: .default
        case .escape?: .cancel
        case .command?, nil: .normal
        }
    }

    static func shortcut(_ hint: CmuxDialogKeyHint) -> KeyboardShortcut {
        switch hint {
        case .return: .defaultAction
        case .escape: .cancelAction
        case .command(let character): KeyboardShortcut(KeyEquivalent(character), modifiers: .command)
        }
    }
}
