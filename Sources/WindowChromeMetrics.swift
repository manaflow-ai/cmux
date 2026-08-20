import CmuxFoundation
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
    static var controlCornerRadius: CGFloat {
        min(10, max(5, controlHeight * 0.25))
    }
    static let headerControlSize: CGFloat = HeaderChromeControlMetrics.buttonSize
    static let headerIconSize: CGFloat = 10
    static let headerIconFrameSize: CGFloat = headerIconSize
    static let headerControlSpacing: CGFloat = 4
    static let headerControlCornerRadius: CGFloat = HeaderChromeControlMetrics.cornerRadius
    static let headerControlCenterAlignmentAdjustment: CGFloat = 0
}

/// Geometry of the floating workspaces card: the rounded glass container
/// the workspaces column renders inside. The machines rail floats directly
/// on the window background with no panel of its own.
enum SidebarFloatingCardMetrics {
    static let cornerRadius: CGFloat = 12
    static let leadingInset: CGFloat = 2
    static let trailingInset: CGFloat = 6
    /// Clears the titlebar band (traffic lights, bell, +) so the card never
    /// intersects window chrome: firstRowTopOffset (30) plus a small gap.
    static let topInset: CGFloat = 34
    /// Clears the region-wide footer (account/help/upgrade strip) below the
    /// card.
    static let bottomInset: CGFloat = 44
    /// How strongly the glass tints toward the resolved terminal theme.
    static let themeTintOpacity: CGFloat = 0.55
    static var horizontalInsets: CGFloat { leadingInset + trailingInset }
}

/// Shared layout language for every first-party sidebar list column.
///
/// Machine, workspace, and future extension-owned columns use these values so
/// a column can change its data without inventing a new visual hierarchy.
enum SidebarListMetrics {
    static let firstRowTopOffset: CGFloat = MinimalModeChromeMetrics.titlebarHeight + 2
    static let rowVerticalPadding: CGFloat = 8
    static let rowOuterHorizontalPadding: CGFloat = 6
    static let rowContentHorizontalPadding: CGFloat = 10
    static let rowContentSpacing: CGFloat = 4
    static let rowCornerRadius: CGFloat = 6
    static let titleFontSize: CGFloat = 12.5
    static let subtitleFontSize: CGFloat = 10
    static let topScrimHeight: CGFloat = firstRowTopOffset + 20
    static let bottomScrimHeight: CGFloat = topScrimHeight

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
    /// Inner insets of the floating workspaces card. The card itself clears
    /// the titlebar and footer bands (SidebarFloatingCardMetrics), so the
    /// list only needs breathing room inside the card.
    static let workspaceList = SidebarWorkspaceScrollInsets(
        top: 8,
        bottom: 12
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
