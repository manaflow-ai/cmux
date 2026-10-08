import UIKit

// MARK: - UITextInputTraits

extension TerminalInputTextView {
    /// Refreshes the active keyboard after the preference changes.
    @objc func handleKeyboardCorrectionPreferenceChanged() {
        guard isFirstResponder else { return }
        reloadInputViews()
    }

    // Autocapitalization and smart punctuation stay off even when corrections
    // are enabled, so a shell command's spelling and punctuation remain intact.
    var autocorrectionType: UITextAutocorrectionType {
        get { keyboardCorrectionPreference.autocorrectionType }
        set {}
    }

    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }

    var spellCheckingType: UITextSpellCheckingType {
        get { keyboardCorrectionPreference.spellCheckingType }
        set {}
    }

    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { keyboardCorrectionPreference.smartInsertDeleteType }
        set {}
    }

    var inlinePredictionType: UITextInlinePredictionType {
        get { keyboardCorrectionPreference.inlinePredictionType }
        set {}
    }

    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
}
