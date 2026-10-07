#if canImport(UIKit)
import UIKit

/// Text sizes follow Dynamic Type at every category, including the
/// accessibility sizes: fonts are re-read from `ConversationTheme` whenever a
/// row is configured, and a category change rebuilds every cached layout.
extension MessageCell {
    func applyScaledFonts() {
        let t = ConversationTheme.self
        senderLabel.font = t.senderNameFont
        quoteLabel.font = t.quoteFont
        footerLabel.font = t.footerFont
        editedLabel.font = t.editedFont
        repliesLabel.font = t.editedFont
        timeLabel.font = t.timestampFont
    }
}

extension UITraitCollection {
    /// Whether a change from `previous` alters text metrics (size or Bold Text).
    func changesTextMetrics(from previous: UITraitCollection?) -> Bool {
        guard let previous else { return false }
        return previous.preferredContentSizeCategory != preferredContentSizeCategory
            || previous.legibilityWeight != legibilityWeight
    }
}
#endif
