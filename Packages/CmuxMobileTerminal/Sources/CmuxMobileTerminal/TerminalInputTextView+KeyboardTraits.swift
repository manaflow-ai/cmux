import UIKit

extension TerminalInputTextView {
    /// Subscribe to ``TerminalKeyboardConfiguration/didChangeNotification`` so the
    /// live keyboard traits track the user's autocorrect preference. Paired with
    /// the blanket `removeObserver(self)` in `deinit`. Called once from `init`.
    func observeKeyboardConfigurationChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardConfigurationChanged),
            name: TerminalKeyboardConfiguration.didChangeNotification,
            object: nil
        )
    }

    /// Apply the user's autocorrect preference to the keyboard input traits.
    ///
    /// When enabled, the autocorrect / predictive text / inline-prediction /
    /// smart-punctuation / spell-check traits fall back to the system default (so
    /// the field behaves like an ordinary iOS text field, respecting the user's
    /// global keyboard settings); when disabled they are forced off for
    /// terminal-hardened input. `inlinePredictionType` is set explicitly because
    /// iOS controls the gray inline suggestion separately from `autocorrectionType`
    /// — without it the off state would still leak inline predictions for users who
    /// enable them system-wide. Autocapitalization is left untouched here — it
    /// stays off unconditionally (set once in `init`). Called from `init` and on
    /// every ``TerminalKeyboardConfiguration/didChangeNotification``.
    func applyKeyboardTraits() {
        let enabled = TerminalKeyboardConfiguration.shared.autocorrectionEnabled
        autocorrectionType = enabled ? .default : .no
        smartQuotesType = enabled ? .default : .no
        smartDashesType = enabled ? .default : .no
        smartInsertDeleteType = enabled ? .default : .no
        spellCheckingType = enabled ? .default : .no
        inlinePredictionType = enabled ? .default : .no
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
