import Testing
@testable import CMUXMobileCore

/// Verifies the pure compose-button decision that keeps the iOS terminal composer
/// coherent across the compose → hide → reveal → compose cycle a user hit on device:
/// the draft must never be dismissed by the compose button while the composer is
/// still logically presented but visually suppressed or unfocused.
@Suite struct ComposerDockReducerTests {
    /// A fresh open: nothing presented, so the button opens the composer.
    @Test func composeButtonOpensWhenNothingPresented() {
        let state = ComposerDockState(
            chromeHidden: false,
            composerPresented: false,
            fieldFocused: false,
            keyboardUp: false
        )
        #expect(state.intentForComposeButtonTap() == .openComposer)
    }

    /// A genuinely visible, focused composer: the button closes it. This is the ONLY
    /// path that dismisses the composer from the button.
    @Test func composeButtonClosesWhenVisibleAndFocused() {
        let state = ComposerDockState(
            chromeHidden: false,
            composerPresented: true,
            fieldFocused: true,
            keyboardUp: true
        )
        #expect(state.intentForComposeButtonTap() == .closeComposer)
    }

    /// Composer presented but the HIDE button suppressed the chrome: the button must
    /// REVEAL + focus, not close (closing here is what lost the draft on device).
    @Test func composeButtonRevealsWhenPresentedButChromeHidden() {
        let state = ComposerDockState(
            chromeHidden: true,
            composerPresented: true,
            fieldFocused: false,
            keyboardUp: false
        )
        #expect(state.intentForComposeButtonTap() == .revealAndFocusComposer)
    }

    /// The exact device-trace state: after a reveal-from-hide the chrome is back and
    /// the composer is presented, but the terminal proxy (not the field) holds first
    /// responder. The button must REVEAL + focus the field, not toggle the composer
    /// closed.
    @Test func composeButtonRefocusesWhenPresentedAndVisibleButFieldUnfocused() {
        let state = ComposerDockState(
            chromeHidden: false,
            composerPresented: true,
            fieldFocused: false,
            keyboardUp: false
        )
        #expect(state.intentForComposeButtonTap() == .revealAndFocusComposer)
    }

    /// End-to-end: replay the reported compose → hide → reveal → compose sequence as
    /// pure state transitions and assert the final compose tap ends in a presented,
    /// focused composer (draft preserved), never a close.
    @Test func composeHideRevealComposeKeepsComposerPresentedAndFocused() {
        // 1. Compose: open from nothing. Intent = open.
        var state = ComposerDockState(
            chromeHidden: false,
            composerPresented: false,
            fieldFocused: false,
            keyboardUp: false
        )
        #expect(state.intentForComposeButtonTap() == .openComposer)

        // After open: composer presented, field focused, keyboard up.
        state.composerPresented = true
        state.fieldFocused = true
        state.keyboardUp = true

        // 2. Hide: chrome suppressed, keyboard dropped, field loses first responder.
        //    `composerPresented` stays true (HIDE never dismisses), so the draft lives.
        state.chromeHidden = true
        state.fieldFocused = false
        state.keyboardUp = false
        #expect(state.composerPresented)

        // 3. Reveal (terminal tap): chrome returns but the terminal proxy takes first
        //    responder, so the composer field is NOT focused yet.
        state.chromeHidden = false
        state.fieldFocused = false
        #expect(state.composerPresented)

        // 4. Compose again: presented + visible + field-unfocused → reveal/refocus,
        //    NOT close. The composer (and its draft) stays.
        #expect(state.intentForComposeButtonTap() == .revealAndFocusComposer)
    }
}
