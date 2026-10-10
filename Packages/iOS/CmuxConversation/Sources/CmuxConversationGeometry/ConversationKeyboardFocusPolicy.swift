/// Keyboard hidden means the composer is not first responder.
///
/// A text view that stays first responder after its keyboard left cannot
/// bring the keyboard back: a tap on it only shows the edit menu. Every path
/// that hides the keyboard (an interactive dismissal, a drawer, a presented
/// picker) ends with the same check, made once, when UIKit reports the
/// keyboard hidden.
public enum ConversationKeyboardFocusPolicy {
    /// What the conversation knows when the keyboard finished hiding.
    public struct KeyboardHidden: Equatable, Sendable {
        public var composerIsFirstResponder: Bool
        /// The keyboard layout guide sits at the bottom safe-area edge. An
        /// undocked or floating keyboard (iPad) keeps it elsewhere while it
        /// still edits the field.
        public var keyboardGuideAtRest: Bool
        /// A hardware keyboard hides the software one and keeps typing.
        public var hardwareKeyboardAttached: Bool
        /// Leaving the app hides the keyboard, and UIKit brings it back on return.
        public var sceneIsForegroundActive: Bool
        /// A rotation or resize can hide and reshow the keyboard (iOS 27).
        public var isTransitioningSize: Bool

        public init(
            composerIsFirstResponder: Bool,
            keyboardGuideAtRest: Bool,
            hardwareKeyboardAttached: Bool,
            sceneIsForegroundActive: Bool,
            isTransitioningSize: Bool
        ) {
            self.composerIsFirstResponder = composerIsFirstResponder
            self.keyboardGuideAtRest = keyboardGuideAtRest
            self.hardwareKeyboardAttached = hardwareKeyboardAttached
            self.sceneIsForegroundActive = sceneIsForegroundActive
            self.isTransitioningSize = isTransitioningSize
        }
    }

    /// Whether the composer should resign now that the keyboard is gone.
    public static func composerResigns(after state: KeyboardHidden) -> Bool {
        state.composerIsFirstResponder
            && state.keyboardGuideAtRest
            && !state.hardwareKeyboardAttached
            && state.sceneIsForegroundActive
            && !state.isTransitioningSize
    }
}
