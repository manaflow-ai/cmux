import UIKit

// MARK: - UITextInputTraits

extension TerminalInputTextView {
    /// Refreshes the active keyboard after the preference changes.
    @objc func handleKeyboardCorrectionPreferenceChanged() {
        guard isFirstResponder else { return }
        reloadInputViews()
    }

    /// Keeps autocorrection disabled because this responder cannot replace sent bytes.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }

    /// Keeps autocapitalization disabled for literal terminal input.
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }

    /// Enables spell checking only when the user opts into corrections.
    var spellCheckingType: UITextSpellCheckingType {
        get { keyboardCorrectionPreference.spellCheckingType }
        set {}
    }

    /// Keeps smart quote substitutions disabled for shell syntax.
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    /// Keeps smart dash substitutions disabled for shell syntax.
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }

    /// Keeps smart insertion/deletion disabled because it mutates terminal bytes.
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }

    /// Enables inline predictions only when corrections are enabled.
    var inlinePredictionType: UITextInlinePredictionType {
        get { keyboardCorrectionPreference.inlinePredictionType }
        set {}
    }

    /// Uses the default keyboard layout for terminal input.
    var keyboardType: UIKeyboardType { get { .default } set {} }
    /// Uses the default return key for terminal input.
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
}
