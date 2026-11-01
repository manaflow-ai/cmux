#if os(iOS)
import UIKit

extension TerminalComposerPromptEditor {
    /// Configures shell-safe text input traits and the optional correction features.
    /// - Parameters:
    ///   - textView: The composer text view to configure.
    ///   - textRewritingEnabled: Whether iOS corrections and predictions are enabled.
    static func configureTextInputTraits(
        _ textView: UITextView,
        textRewritingEnabled: Bool = false
    ) {
        textView.autocapitalizationType = .none
        textView.autocorrectionType = textRewritingEnabled ? .yes : .no
        textView.spellCheckingType = textRewritingEnabled ? .yes : .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = textRewritingEnabled ? .yes : .no
        textView.inlinePredictionType = textRewritingEnabled ? .yes : .no
    }

    /// Reconfigures the keyboard only when the correction preference changes.
    /// - Parameters:
    ///   - textView: The composer text view whose traits may need updating.
    ///   - textRewritingEnabled: The desired correction and prediction state.
    static func updateTextInputTraits(
        _ textView: UITextView,
        textRewritingEnabled: Bool
    ) {
        let desired = textRewritingEnabled ? UITextAutocorrectionType.yes : .no
        guard textView.autocorrectionType != desired else { return }
        configureTextInputTraits(textView, textRewritingEnabled: textRewritingEnabled)
        if textView.isFirstResponder {
            textView.reloadInputViews()
        }
    }
}
#endif
