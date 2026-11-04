#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// The host's text size (`textSize`): the controller draws at that Dynamic
/// Type size instead of the person's own. Its traits carry the size, so
/// UIKit text follows it and every row re-measures through the same path a
/// Dynamic Type change takes; `ConversationTheme` resolves its text styles
/// at the size of the conversation in front (`ConversationTextSizeOwners`),
/// including for rows measured off the main thread.
extension ConversationViewController {
    func applyTextSize() {
        guard isViewLoaded else { return }
        if let category = textSize?.contentSizeCategory {
            traitOverrides.preferredContentSizeCategory = category
        } else if traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
            traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
        ConversationTextSizeOwners.changed(self)
    }

    /// What the theme resolves fonts with while this conversation is in front.
    var themeTextSizeTraits: UITraitCollection? {
        guard let size = textSize else { return nil }
        let legibility = traitCollection.legibilityWeight
        return UITraitCollection { traits in
            traits.preferredContentSizeCategory = size.contentSizeCategory
            traits.legibilityWeight = legibility
        }
    }

    /// The theme's text size changed. Rows, the composer and the header
    /// measured under another conversation's size are laid out again once
    /// the theme is this conversation's own (now, or when it is in front again).
    func themeTextSizeDidChange() {
        guard isViewLoaded else { return }
        guard ConversationTextSizeOwners.sameSize(ConversationTheme.textSizeTraits, themeTextSizeTraits) else { return }
        if composer.textView.font?.pointSize != ConversationTheme.bodyFont.pointSize { composer.applyScaledFonts() }
        header.applyScaledFonts()
        relayoutForTextMetrics()
    }
}

/// The conversations on screen, front last. The theme's fonts follow the
/// front one's host text size; when it goes (a sheet closes, a pushed one
/// pops), the one under it takes the theme back and re-measures what it
/// laid out meanwhile. With no host size anywhere the theme never changes.
@MainActor
enum ConversationTextSizeOwners {
    private struct Owner { weak var controller: ConversationViewController? }
    private static var owners: [Owner] = []

    /// `controller` is in front now (`viewWillAppear`).
    static func appeared(_ controller: ConversationViewController) {
        owners.removeAll { $0.controller == nil || $0.controller === controller }
        owners.append(Owner(controller: controller))
        apply()
    }

    /// `controller` is off screen (`viewDidDisappear`).
    static func disappeared(_ controller: ConversationViewController) {
        owners.removeAll { $0.controller == nil || $0.controller === controller }
        apply()
    }

    /// `controller`'s size (or Bold Text) changed.
    static func changed(_ controller: ConversationViewController) {
        guard owners.last?.controller === controller else { return }
        apply()
    }

    static func sameSize(_ a: UITraitCollection?, _ b: UITraitCollection?) -> Bool {
        a?.preferredContentSizeCategory == b?.preferredContentSizeCategory && a?.legibilityWeight == b?.legibilityWeight
    }

    private static func apply() {
        let wanted = owners.last?.controller?.themeTextSizeTraits
        guard !sameSize(ConversationTheme.textSizeTraits, wanted) else { return }
        ConversationTheme.textSizeTraits = wanted
        ConversationTheme.textSizeEpoch += 1
        for owner in owners { owner.controller?.themeTextSizeDidChange() }
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
