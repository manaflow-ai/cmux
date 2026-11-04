#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// The host's text size (`textSize`): the controller draws at that Dynamic
/// Type size instead of the person's own. Its traits carry the size, so
/// UIKit text follows it and every row re-measures through the same path a
/// Dynamic Type change takes; `ConversationTheme` resolves its text styles
/// at the size too, including for rows measured off the main thread.
extension ConversationViewController {
    func applyTextSize() {
        guard isViewLoaded else { return }
        if let category = textSize?.contentSizeCategory {
            traitOverrides.preferredContentSizeCategory = category
        } else if traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
            traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
        // On screen the theme takes the size at once, and the trait change
        // that follows (next layout) re-measures the rows; otherwise it
        // takes it when the conversation appears (`viewWillAppear`).
        if view.window != nil { _ = adoptThemeTextSize() }
    }

    /// Points the theme at this controller's text size. Returns whether it
    /// changed what the theme resolves fonts with.
    func adoptThemeTextSize() -> Bool {
        let wanted: UITraitCollection? = textSize.map { size in
            let legibility = traitCollection.legibilityWeight
            return UITraitCollection { traits in
                traits.preferredContentSizeCategory = size.contentSizeCategory
                traits.legibilityWeight = legibility
            }
        }
        let current = ConversationTheme.textSizeTraits
        guard wanted?.preferredContentSizeCategory != current?.preferredContentSizeCategory
            || wanted?.legibilityWeight != current?.legibilityWeight else { return false }
        ConversationTheme.textSizeTraits = wanted
        return true
    }
}

extension ConversationTextSize {
    /// The Dynamic Type category this size is.
    public var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .extraSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .extraLarge: .extraLarge
        case .extraExtraLarge: .extraExtraLarge
        case .extraExtraExtraLarge: .extraExtraExtraLarge
        case .accessibilityMedium: .accessibilityMedium
        case .accessibilityLarge: .accessibilityLarge
        case .accessibilityExtraLarge: .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: .accessibilityExtraExtraExtraLarge
        }
    }

    /// The size for a Dynamic Type category; nil for `.unspecified`.
    public init?(_ category: UIContentSizeCategory) {
        guard let size = Self.allCases.first(where: { $0.contentSizeCategory == category }) else { return nil }
        self = size
    }
}
#endif
