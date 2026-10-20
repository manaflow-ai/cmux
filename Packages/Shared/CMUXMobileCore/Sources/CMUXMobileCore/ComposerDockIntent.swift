/// The single coherent step the surface should take in response to a compose-button
/// tap, computed by ``ComposerDockState/intentForComposeButtonTap()``.
public enum ComposerDockIntent: Sendable, Equatable {
    /// No composer is presented; present it and focus the field (the plain open).
    case openComposer
    /// A composer is presented but suppressed or unfocused; reveal the chrome (if
    /// hidden), keep it presented, and focus the field. The draft is preserved.
    case revealAndFocusComposer
    /// A genuinely visible, focused composer; dismiss it (the only path that closes
    /// the composer from the button).
    case closeComposer
}
