import AppKit
import CmuxFoundation
import CoreGraphics
import SwiftUI

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

/// The workspace card: the titlebar band plus the terminal panes framed as
/// one rounded surface, the way Onyx and Aside frame their content. The card
/// is pure SwiftUI drawn behind the portal-hosted terminal: its fill and
/// border only show through in the band strip and the gaps around the panes,
/// so nothing has to clip the terminal's own AppKit layers.
enum WorkspaceCardMetrics {
    static let cornerRadius: CGFloat = 16
    static let borderWidth: CGFloat = 1
    /// Pane edge to card edge where the card meets the window edge.
    static let paneInset: CGFloat = 8
    /// The bottom leading corner sits under a pane that meets the sidebar,
    /// so its curve has to end where the pane's square corner starts: a
    /// continuous corner's curve runs about 1.53 radii along each edge, and
    /// it must fit in the bottom inset.
    static let bottomLeadingCornerRadius: CGFloat = paneInset / 1.53
}

/// The card surface, filled with the terminal's own background colour.
///
/// Matching the terminal is the whole design: the pane insets stop reading
/// as a frame-within-a-frame because the gap is the same colour as the pane,
/// and the pane's square corners vanish against the identically coloured
/// card behind them. The eye sees exactly two surfaces: the window chrome,
/// and one rounded content card.
struct WorkspaceCardBackground: View {
    let fill: NSColor

    var body: some View {
        // Rounded only where the card meets the glass: the leading corners.
        // The trailing and bottom edges run flush to the window, so rounding
        // them would just notch the window's own frame. No stroke: the card
        // is one surface against the glass, separated by fill and rounding
        // alone.
        UnevenRoundedRectangle(
            topLeadingRadius: WorkspaceCardMetrics.cornerRadius,
            bottomLeadingRadius: WorkspaceCardMetrics.bottomLeadingCornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color(nsColor: fill))
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
    static let topScrimHeight: CGFloat = firstRowTopOffset + 20
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

    /// Compact top metrics for the floating panel: its window already starts
    /// below the titlebar, so the docked pane's reserved titlebar band is
    /// dead space there.
    static let compactScrollTopInset: CGFloat = 8
    static let compactTopScrimHeight: CGFloat = 24
}

struct SidebarWorkspaceScrollInsets: Equatable {
    static let workspaceList = SidebarWorkspaceScrollInsets(
        top: SidebarWorkspaceListMetrics.scrollTopInset,
        bottom: SidebarWorkspaceListMetrics.bottomScrimHeight
    )

    /// The floating panel's list: same bottom (the footer still lives
    /// there), compact top (no titlebar band to clear).
    static let floatingPanel = SidebarWorkspaceScrollInsets(
        top: SidebarWorkspaceListMetrics.compactScrollTopInset,
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
