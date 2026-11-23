import SwiftUI

/// Draws a SwiftUI `Button` as a cmux dialog button (``CmuxDialogButtonView``'s ``CmuxDialogButtonLook``): a theme
/// fill, a title at 4.5:1 on it over the card, the theme's hover and press, and a focus ring fit to 3:1. SwiftUI
/// keeps the button's click, key equivalent, focus and accessibility; the look only draws.
///
/// A stock SwiftUI button draws AppKit's bezel and label in the window's appearance, not the theme's tokens: on a
/// popover's glass it showed no fill and a dimmed title, so the bookmark bubble's More… and Remove read as
/// disabled next to Done (a1273). ``CmuxDialogActionButton`` uses this style.
struct CmuxDialogButtonStyle: ButtonStyle {
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
