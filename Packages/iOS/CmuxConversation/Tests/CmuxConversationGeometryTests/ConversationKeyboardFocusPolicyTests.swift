import CmuxConversationGeometry
import Testing

/// Keyboard hidden means the composer is not first responder, so one tap on
/// the field always brings the keyboard back.
@Suite struct ConversationKeyboardFocusPolicyTests {
    /// The keyboard went away on an iPhone in the foreground, as an
    /// interactive dismissal (drag, fling, early release) leaves it.
    let dismissed = ConversationKeyboardFocusPolicy.KeyboardHidden(
        composerIsFirstResponder: true,
        keyboardGuideAtRest: true,
        hardwareKeyboardAttached: false,
        sceneIsForegroundActive: true,
        isTransitioningSize: false
    )

    @Test func aFocusedComposerResignsOnceTheKeyboardIsGone() {
        #expect(ConversationKeyboardFocusPolicy.composerResigns(after: dismissed))
    }

    @Test func nothingToDoWhenTheComposerAlreadyResigned() {
        var state = dismissed
        state.composerIsFirstResponder = false
        #expect(!ConversationKeyboardFocusPolicy.composerResigns(after: state))
    }

    /// A hardware keyboard hides the software one; the field keeps typing.
    @Test func aHardwareKeyboardKeepsTheFieldFocused() {
        var state = dismissed
        state.hardwareKeyboardAttached = true
        #expect(!ConversationKeyboardFocusPolicy.composerResigns(after: state))
    }

    /// Leaving the app hides the keyboard; UIKit brings it back on return.
    @Test func backgroundingKeepsTheFieldFocused() {
        var state = dismissed
        state.sceneIsForegroundActive = false
        #expect(!ConversationKeyboardFocusPolicy.composerResigns(after: state))
    }

    /// iOS 27 hides and reshows the keyboard around a rotation.
    @Test func rotationKeepsTheFieldFocused() {
        var state = dismissed
        state.isTransitioningSize = true
        #expect(!ConversationKeyboardFocusPolicy.composerResigns(after: state))
    }

    /// An undocked or floating keyboard (iPad) still holds the guide.
    @Test func anUndockedKeyboardKeepsTheFieldFocused() {
        var state = dismissed
        state.keyboardGuideAtRest = false
        #expect(!ConversationKeyboardFocusPolicy.composerResigns(after: state))
    }
}
