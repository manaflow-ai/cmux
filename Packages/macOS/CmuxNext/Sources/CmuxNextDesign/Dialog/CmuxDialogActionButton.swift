import AppKit
public import SwiftUI

/// A SwiftUI dialog or sheet button that shows the key pressing it and binds that key
/// (u2647): the SwiftUI twin of ``CmuxDialogButtonView``, drawn in its look (`CmuxDialogButtonStyle`, below), so it reads
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

/// Draws a SwiftUI `Button` as a cmux dialog button (``CmuxDialogButtonView``'s ``CmuxDialogButtonLook``): a theme
/// fill, a title at 4.5:1 on it over the card, the theme's hover and press, and a focus ring fit to 3:1. SwiftUI
/// keeps the button's click, key equivalent, focus and accessibility; the look only draws.
///
/// A stock SwiftUI button draws AppKit's bezel and label in the window's appearance, not the theme's tokens: on a
/// popover's glass it showed no fill and a dimmed title, so the bookmark bubble's More… and Remove read as
/// disabled next to Done (a1273). ``CmuxDialogActionButton`` uses this style.
private struct CmuxDialogButtonStyle: ButtonStyle {
    let button: CmuxDialogButton
    let hint: CmuxDialogKeyHint?

    /// - Parameters:
    ///   - button: The title and role the look draws (`.default` the accent fill, `.destructive` the danger one,
    ///     `.cancel` and `.normal` the theme gray).
    ///   - hint: The key drawn after the title; nil draws none. It only labels the key: bind it on the `Button`
    ///     (`.keyboardShortcut`).
    init(_ button: CmuxDialogButton, hint: CmuxDialogKeyHint?) {
        self.button = button
        self.hint = hint
    }

    func makeBody(configuration: Configuration) -> some View {
        CmuxDialogButtonFace(button: button, hint: hint, isPressed: configuration.isPressed)
    }
}

/// The face of a ``CmuxDialogButtonStyle`` button: the button's focus and enabled state, passed to the
/// ``CmuxDialogButtonView`` that draws it.
private struct CmuxDialogButtonFace: View {
    let button: CmuxDialogButton
    let hint: CmuxDialogKeyHint?
    let isPressed: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        CmuxDialogButtonFaceView(button: button, hint: hint, isPressed: isPressed, isFocused: isFocused, isEnabled: isEnabled)
            // A role or key change is another button: AppKit's view keeps both from its init.
            .id("\(button.role.rawValue) \(hint?.glyph ?? "")")
            // The click is the SwiftUI button's: the drawing takes none, the shape under it takes them all.
            .allowsHitTesting(false)
            .background(Color.clear.contentShape(Rectangle()))
    }
}

/// A ``CmuxDialogButtonView`` that only draws (``CmuxDialogButtonView/isFace``): the SwiftUI button around it takes
/// the clicks, the keys and the focus.
private struct CmuxDialogButtonFaceView: NSViewRepresentable {
    let button: CmuxDialogButton
    let hint: CmuxDialogKeyHint?
    let isPressed: Bool
    let isFocused: Bool
    let isEnabled: Bool

    func makeNSView(context: Context) -> CmuxDialogButtonView {
        let view = CmuxDialogButtonView(button, hint: hint, target: nil, action: Self.noAction)
        view.isFace = true
        view.action = nil
        // SwiftUI places the view by its frame: no Auto Layout height of its own.
        NSLayoutConstraint.deactivate(view.constraints.filter { $0.firstItem === view && $0.firstAttribute == .height })
        view.translatesAutoresizingMaskIntoConstraints = true
        view.setAccessibilityElement(false)
        update(view)
        return view
    }

    /// The init wants an action; a face sends none (SwiftUI's button runs it).
    private static let noAction = Selector(("cmuxDialogFaceSendsNoAction"))

    func updateNSView(_ view: CmuxDialogButtonView, context: Context) { update(view) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CmuxDialogButtonView, context: Context) -> CGSize? {
        view.intrinsicContentSize
    }

    private func update(_ view: CmuxDialogButtonView) {
        view.retitle(button.title)
        if view.isEnabled != isEnabled { view.isEnabled = isEnabled }
        view.hasFocus = isFocused
        let state: CmuxDialogButtonLook.State? = isPressed ? .pressed : nil
        if view.previewState != state { view.previewState = state }
    }
}
