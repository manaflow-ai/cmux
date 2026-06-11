/// The four booleans that describe the iOS terminal's bottom dock at the instant
/// the user acts on the composer, plus the pure decision that maps an action onto
/// the one coherent next step.
///
/// The bottom dock is a tangle of four independent flags — chrome hidden vs shown,
/// composer logically presented vs not, the composer field holding first responder
/// vs not, and the software keyboard up vs down. A blind `isComposerPresented.toggle()`
/// on the compose button ignored all of them, so the cycle compose → hide → reveal →
/// compose closed a still-presented (but visually suppressed, or revealed-yet-unfocused)
/// composer and the user saw their draft vanish. This type is the single source of
/// truth for that decision so it can be unit-tested off-device and the UIKit surface
/// only has to translate the resulting ``ComposerDockIntent`` into calls.
public struct ComposerDockState: Sendable, Equatable {
    /// Whether the HIDE button has visually suppressed the whole bottom chrome
    /// (toolbar + composer band). The composer can be *presented* yet hidden:
    /// HIDE leaves ``composerPresented`` untouched and only drops the chrome, so
    /// the draft survives.
    public var chromeHidden: Bool
    /// Whether the composer is logically presented (the store's `isComposerPresented`,
    /// mirrored onto the surface). True from the moment the composer opens until it
    /// is genuinely dismissed; a HIDE does not flip it.
    public var composerPresented: Bool
    /// Whether the composer's text field currently holds first responder. After a
    /// reveal-from-hide the chrome is back and the composer is presented, but the
    /// terminal proxy (not the field) took first responder, so this is false — the
    /// exact state that made the next compose tap destructive.
    public var fieldFocused: Bool
    /// Whether the software keyboard is currently up.
    ///
    /// Part of the dock's complete description, recorded so a captured trace and the
    /// tests model the real state. It does NOT gate
    /// ``intentForComposeButtonTap()`` today (the open/reveal/close decision turns
    /// only on presented + suppressed/unfocused); it is retained for the dock's
    /// faithful shape and any future keyboard-aware step.
    public var keyboardUp: Bool

    /// Creates a dock state from its four flags.
    /// - Parameters:
    ///   - chromeHidden: Whether the HIDE button has suppressed the chrome.
    ///   - composerPresented: Whether the composer is logically presented.
    ///   - fieldFocused: Whether the composer field holds first responder.
    ///   - keyboardUp: Whether the software keyboard is up.
    public init(
        chromeHidden: Bool,
        composerPresented: Bool,
        fieldFocused: Bool,
        keyboardUp: Bool
    ) {
        self.chromeHidden = chromeHidden
        self.composerPresented = composerPresented
        self.fieldFocused = fieldFocused
        self.keyboardUp = keyboardUp
    }

    /// Resolve what tapping the compose accessory button should do, given this dock
    /// state.
    ///
    /// The compose button has three jobs folded into one control, told apart by the
    /// dock state:
    ///
    /// - **Open** when no composer is presented: present it and focus the field.
    /// - **Reveal** when a composer is presented but suppressed (``chromeHidden``)
    ///   or visible-yet-unfocused (presented, chrome shown, field not first
    ///   responder — the reveal-after-hide state): bring the chrome back, keep the
    ///   composer presented, and focus the field. The draft is never dismissed.
    /// - **Close** only when the composer is genuinely visible and focused: a real
    ///   "I'm done composing" tap.
    ///
    /// - Returns: the ``ComposerDockIntent`` the surface should carry out.
    public func intentForComposeButtonTap() -> ComposerDockIntent {
        guard composerPresented else {
            // Nothing presented: a plain open.
            return .openComposer
        }
        if chromeHidden || !fieldFocused {
            // Presented but suppressed, or presented-and-visible yet the field lost
            // first responder on a reveal. Either way the user wants the composer
            // back and focused, NOT dismissed — reveal the chrome if needed and
            // re-focus the field, leaving the draft intact.
            return .revealAndFocusComposer
        }
        // Genuinely visible and focused: a real close.
        return .closeComposer
    }
}
