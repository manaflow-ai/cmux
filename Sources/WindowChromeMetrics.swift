import CmuxFoundation
import CmuxSettings
import CoreGraphics

enum WindowChromeMetrics {
    static let sharedChromeBarHeight: CGFloat = 28
    static let appTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let bonsplitTabBarHeight: CGFloat = sharedChromeBarHeight
    static let secondaryTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let minimumTitlebarHeight: CGFloat = sharedChromeBarHeight
    static let maximumTitlebarHeight: CGFloat = 72
    static let defaultTitlebarHeight: CGFloat = sharedChromeBarHeight

    static func clampedTitlebarHeight(_ height: CGFloat) -> CGFloat {
        max(minimumTitlebarHeight, min(maximumTitlebarHeight, height))
    }
}

enum MinimalModeChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
}

enum HeaderChromeControlMetrics {
    static let buttonSize: CGFloat = 20
    static let iconSize: CGFloat = 12
    static let iconFrameSize: CGFloat = 14
    static let cornerRadius: CGFloat = 6
    static let titlebarControlsLeadingPadding: CGFloat = 4

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        max(Self.iconFrameSize, iconSize + 2)
    }
}

/// Control sizes for each `app.density` level.
///
/// `standard` is the set cmux shipped before the setting: 20pt titlebar
/// buttons with 12pt glyphs and 22pt sidebar footer buttons with 14pt glyphs.
/// The macOS HIG lists 28x28pt as the default control size and 20x20pt as
/// the minimum, so `standard` sits at or just above the minimum.
/// `comfortable` moves toward the default while still fitting the 28pt
/// titlebar row, and `compact` shrinks glyphs without going under 20pt.
struct InterfaceDensityMetrics: Equatable {
    /// Square hit target of each titlebar control button.
    let titlebarButtonSize: CGFloat
    /// SF Symbol point size inside titlebar control buttons.
    let titlebarIconSize: CGFloat
    /// Unread-count badge diameter on the titlebar notifications button.
    let titlebarBadgeSize: CGFloat
    /// Gap between titlebar control buttons.
    let titlebarSpacing: CGFloat
    /// Square hit target of each sidebar footer button.
    let sidebarFooterButtonSize: CGFloat
    /// Glyph size for the account and help buttons.
    let sidebarFooterPrimaryIconSize: CGFloat
    /// Glyph size for the lighter footer glyphs (mobile, extensions).
    let sidebarFooterSecondaryIconSize: CGFloat

    static let comfortable = InterfaceDensityMetrics(
        titlebarButtonSize: 24,
        titlebarIconSize: 14,
        titlebarBadgeSize: 13,
        titlebarSpacing: 4,
        sidebarFooterButtonSize: 26,
        sidebarFooterPrimaryIconSize: 16,
        sidebarFooterSecondaryIconSize: 14
    )

    static let standard = InterfaceDensityMetrics(
        titlebarButtonSize: HeaderChromeControlMetrics.buttonSize,
        titlebarIconSize: HeaderChromeControlMetrics.iconSize,
        titlebarBadgeSize: 12,
        titlebarSpacing: 6,
        sidebarFooterButtonSize: 22,
        sidebarFooterPrimaryIconSize: 14,
        sidebarFooterSecondaryIconSize: 12
    )

    static let compact = InterfaceDensityMetrics(
        titlebarButtonSize: 20,
        titlebarIconSize: 11,
        titlebarBadgeSize: 11,
        titlebarSpacing: 4,
        sidebarFooterButtonSize: 20,
        sidebarFooterPrimaryIconSize: 13,
        sidebarFooterSecondaryIconSize: 11
    )

    static func metrics(for density: InterfaceDensity) -> InterfaceDensityMetrics {
        switch density {
        case .comfortable: return .comfortable
        case .standard: return .standard
        case .compact: return .compact
        }
    }
}

enum RightSidebarChromeMetrics {
    static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
    static var secondaryBarHeight: CGFloat {
        controlHeight + (barVerticalPadding * 2)
    }
    static let barHorizontalPadding: CGFloat = 8
    static let barVerticalPadding: CGFloat = 4
    static var controlHeight: CGFloat {
        let baseHeight = WindowChromeMetrics.secondaryTitlebarHeight - (barVerticalPadding * 2)
        let scaledTextHeight = GlobalFontMagnification.scaledSize(12)
        let scaledContentHeight = scaledTextHeight + 8
        return max(baseHeight, scaledContentHeight)
    }
    static let controlHorizontalPadding: CGFloat = 8
    static let contentIconLeadingPadding: CGFloat = 12
    static let contentIconFrameSize: CGFloat = 14
    static let contentIconTextSpacing: CGFloat = 4
    static var contentTextLeadingPadding: CGFloat {
        contentIconLeadingPadding + contentIconFrameSize + contentIconTextSpacing
    }
    static var contentIconCenter: CGFloat {
        contentIconLeadingPadding + contentIconFrameSize / 2
    }
    /// Corner radius for every right-sidebar button: header icon buttons,
    /// mode and grouping pills, panel action buttons, and system bordered
    /// buttons (via `rightSidebarButtonBorderShape()`).
    static let buttonCornerRadius: CGFloat = HeaderChromeControlMetrics.cornerRadius
    static let headerControlSize: CGFloat = HeaderChromeControlMetrics.buttonSize
    static let headerIconSize: CGFloat = 10
    static let headerIconFrameSize: CGFloat = headerIconSize
    static let headerControlSpacing: CGFloat = 4
    /// Outer insets of the right-sidebar chrome bars. The mode bar, the Vault
    /// grouping pills, and the Vault search row all use these, so their
    /// controls share one leading column and one trailing column.
    static let headerLeadingPadding: CGFloat = HeaderChromeControlMetrics.titlebarControlsLeadingPadding
    static let headerTrailingPadding: CGFloat = 6
    static let headerControlCornerRadius: CGFloat = buttonCornerRadius
    static let headerControlCenterAlignmentAdjustment: CGFloat = 0
}

enum SidebarWorkspaceListMetrics {
    static let firstRowTopOffset: CGFloat = MinimalModeChromeMetrics.titlebarHeight + 2
    static let rowVerticalPadding: CGFloat = 8
    static let rowOuterHorizontalPadding: CGFloat = 6
    static let rowContentHorizontalPadding: CGFloat = 10
    /// The top fade ends where the first row rests, so rows fade only while
    /// scrolled under the titlebar. It used to reach 20 pt into the list,
    /// which left the first row partly transparent at rest; over a light
    /// terminal-matched backdrop that washed out the selected row's top.
    static let topScrimHeight: CGFloat = firstRowTopOffset
    static let bottomScrimHeight: CGFloat = firstRowTopOffset + 20

    static var trailingAccessoryRightEdgeOffset: CGFloat {
        rowOuterHorizontalPadding + rowContentHorizontalPadding
    }

    static func trailingAccessoryCenterOffset(controlWidth: CGFloat) -> CGFloat {
        trailingAccessoryRightEdgeOffset + (controlWidth / 2)
    }

    static var scrollTopInset: CGFloat {
        max(0, firstRowTopOffset - rowVerticalPadding)
    }
}

struct SidebarWorkspaceScrollInsets: Equatable {
    static let workspaceList = SidebarWorkspaceScrollInsets(
        top: SidebarWorkspaceListMetrics.scrollTopInset,
        bottom: SidebarWorkspaceListMetrics.bottomScrimHeight
    )

    let top: CGFloat
    let bottom: CGFloat

    nonisolated var total: CGFloat {
        top + bottom
    }
}

enum SidebarWorkspaceScrollLayout {
    nonisolated static func contentMinHeight(
        viewportHeight: CGFloat,
        insets: SidebarWorkspaceScrollInsets
    ) -> CGFloat {
        // Floor the available height to a whole point. The scroll content is
        // sized to fill exactly `viewportHeight - insets.total`, but on
        // Retina/scaled displays the viewport is frequently fractional and
        // AppKit aligns the laid-out document view's frame to the backing store
        // (rounding up), so a fractional value can land just past the viewport.
        // That sub-point overflow makes the content barely scrollable and shows
        // the auto-hiding overlay scroller even with a single workspace.
        // Flooring to a whole point keeps `content + insets <= viewportHeight`
        // regardless of the display's backing scale, so the phantom scrollbar
        // stays hidden when content fits
        // (https://github.com/manaflow-ai/cmux/issues/3241).
        return max(0, (viewportHeight - insets.total).rounded(.down))
    }
}
