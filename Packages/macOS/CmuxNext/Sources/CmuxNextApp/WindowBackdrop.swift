import CoreGraphics

/// How the window behind the terminal is set up for `background-opacity`
/// and `background-blur`, by Ghostty's rules
/// (ghostty/macos/Sources/Features/Terminal/Window Styles/TerminalWindow.swift
/// `syncAppearance`): the window is non-opaque for a translucent background
/// or a macOS glass style; its own background is white at alpha 0.001 (not
/// clear, as in Terminal.app), and non-glass styles get the CGS blur radius
/// (`ghostty_set_window_background_blur`, a no-op while opaque).
struct WindowBackdrop: Equatable {
    var isOpaque: Bool
    var appliesBlur: Bool
    /// Alpha of the white window background while non-opaque.
    let windowBackgroundAlpha: CGFloat = 0.001

    /// `backgroundBlur` in Ghostty's C encoding: 0 off, > 0 radius, -1/-2
    /// macOS glass styles.
    init(backgroundOpacity: Double, backgroundBlur: Int) {
        let glass = backgroundBlur < 0
        isOpaque = backgroundOpacity >= 1 && !glass
        appliesBlur = backgroundOpacity < 1 && !glass
    }
}
