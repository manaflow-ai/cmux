import UIKit

extension TerminalInputTextView {
    /// Subscribe to ``TerminalKeyboardConfiguration/didChangeNotification`` so the
    /// live keyboard traits track the user's autocomplete preference. Paired with
    /// the blanket `removeObserver(self)` in `deinit`. Called once from `init`.
    func observeKeyboardConfigurationChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardConfigurationChanged),
            name: TerminalKeyboardConfiguration.didChangeNotification,
            object: keyboardConfiguration
        )
    }

    /// Apply the user's autocomplete preference to the keyboard input traits.
    ///
    /// The terminal input proxy forwards normal `insertText` bytes directly to
    /// the shell. Replacement-based traits such as autocorrection, smart
    /// punctuation, and spell-checking can rewrite text after those bytes have
    /// already been sent, so they stay off even when autocomplete is enabled.
    /// `inlinePredictionType` is safe to toggle because accepting an inline
    /// prediction appends text through the normal input path. Autocapitalization
    /// is left untouched here — it stays off unconditionally (set once in
    /// `init`). Called from `init` and on every
    /// ``TerminalKeyboardConfiguration/didChangeNotification``.
    func applyKeyboardTraits() {
        autocorrectionType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        inlinePredictionType = keyboardConfiguration.inlinePredictionType
    }

    @objc func handleKeyboardConfigurationChanged() {
        applyKeyboardTraits()
        // Reload only when this view owns the keyboard, so the change takes
        // effect on the live keyboard; otherwise the next `init` / become-first-
        // responder picks up the already-applied traits.
        if isFirstResponder {
            reloadInputViews()
        }
    }
}
