#if canImport(UIKit)
import CmuxConversationCore
import UIKit

/// The host's text size (`textSize`) and bubble colours (`bubbleColors`):
/// the controller draws at that Dynamic Type size and in those colours
/// instead of the defaults. Its traits carry the size, so UIKit text follows
/// it and every row re-measures through the same path a Dynamic Type change
/// takes; `ConversationTheme` resolves text styles and bubble colours from
/// the conversation in front (`ConversationThemeOwners`), including for rows
/// measured off the main thread.
extension ConversationViewController {
    func applyTextSize() {
        guard isViewLoaded else { return }
        if let category = textSize?.contentSizeCategory {
            traitOverrides.preferredContentSizeCategory = category
        } else if traitOverrides.contains(UITraitPreferredContentSizeCategory.self) {
            traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
        ConversationThemeOwners.changed(self)
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

    /// The colours the theme draws bubbles with while this conversation is in front.
    var themeBubbleColors: ConversationBubbleColors? {
        guard let bubbleColors, !bubbleColors.isEmpty else { return nil }
        return bubbleColors
    }

    /// The theme's size or colours changed. Rows, the composer and the
    /// header laid out under another conversation's are laid out again once
    /// the theme is this conversation's own (now, or when it is in front again).
    func themeDidChange(sizeChanged: Bool) {
        guard isViewLoaded,
              ConversationThemeOwners.sameSize(ConversationTheme.textSizeTraits, themeTextSizeTraits),
              ConversationTheme.bubbleColors == themeBubbleColors else { return }
        if sizeChanged {
            if composer.textView.font != ConversationTheme.bodyFont { composer.applyScaledFonts() }
            header.applyScaledFonts()
        }
        relayoutForTextMetrics()
    }
}

/// The conversations on screen, front last. The theme's fonts and bubble
/// colours follow the front one's host size and colours; when it goes (a
/// sheet closes, a pushed one pops), the one under it takes the theme back
/// and lays out again what it laid out meanwhile. With no host size or
/// colours anywhere the theme never changes.
@MainActor
enum ConversationThemeOwners {
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

    /// `controller`'s size, Bold Text or colours changed.
    static func changed(_ controller: ConversationViewController) {
        guard owners.last?.controller === controller else { return }
        apply()
    }

    static func sameSize(_ a: UITraitCollection?, _ b: UITraitCollection?) -> Bool {
        a?.preferredContentSizeCategory == b?.preferredContentSizeCategory && a?.legibilityWeight == b?.legibilityWeight
    }

    private static func apply() {
        let front = owners.last?.controller
        let size = front?.themeTextSizeTraits
        let colors = front?.themeBubbleColors
        let sizeChanged = !sameSize(ConversationTheme.textSizeTraits, size)
        let colorsChanged = ConversationTheme.bubbleColors != colors
        guard sizeChanged || colorsChanged else { return }
        if sizeChanged { ConversationTheme.textSizeTraits = size }
        if colorsChanged { ConversationTheme.bubbleColors = colors }
        ConversationTheme.themeEpoch += 1
        for owner in owners { owner.controller?.themeDidChange(sizeChanged: sizeChanged) }
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
