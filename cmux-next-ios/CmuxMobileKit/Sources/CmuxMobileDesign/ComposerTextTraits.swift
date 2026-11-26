#if os(iOS)
import UIKit

/// Text traits the GUI composers share.
public enum ComposerTextTraits {
    /// Keeps Siri's suggestions from popping up over the composer (Leo, 2026-11-23: block the
    /// Siri popup here): no inline predictions (the grey completion Siri types ahead), no content
    /// type (the contact, address and code cards above the keyboard), no Writing Tools panel.
    /// Autocorrect and the QuickType bar's word candidates stay, so typing still corrects.
    public static func blockSiriSuggestions(_ view: UITextView) {
        view.inlinePredictionType = .no
        view.textContentType = nil
        view.writingToolsBehavior = .none
    }
}
#endif
