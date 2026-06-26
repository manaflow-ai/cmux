import UIKit

// MARK: - UITextInputTraits

extension TerminalInputTextView {
    // These traits are computed from the injected preference so a Settings
    // toggle can reload the active keyboard without rebuilding the terminal
    // surface. Capitalization and smart quotes/dashes stay off because command
    // entry must remain literal even when suggestions are enabled.
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
    var keyboardType: UIKeyboardType { get { .default } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }
}
