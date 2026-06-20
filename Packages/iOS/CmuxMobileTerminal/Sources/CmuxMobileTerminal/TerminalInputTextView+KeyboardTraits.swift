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
    /// When disabled, the terminal input proxy keeps all correction traits off
    /// so commands cannot be rewritten. When enabled, those traits return to the
    /// system default so UIKit respects the user's global keyboard settings; any
    /// replacement edits are translated into terminal cursor/backspace/input
    /// events by ``TerminalInputTextView`` before the proxy buffer is cleared.
    /// Autocapitalization is left untouched here — it stays off unconditionally
    /// (set once in `init`). Called from `init` and on every
    /// ``TerminalKeyboardConfiguration/didChangeNotification``.
    func applyKeyboardTraits() {
        let enabled = keyboardConfiguration.autocompleteEnabled
        autocorrectionType = enabled ? .default : .no
        smartQuotesType = enabled ? .default : .no
        smartDashesType = enabled ? .default : .no
        smartInsertDeleteType = enabled ? .default : .no
        spellCheckingType = enabled ? .default : .no
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
