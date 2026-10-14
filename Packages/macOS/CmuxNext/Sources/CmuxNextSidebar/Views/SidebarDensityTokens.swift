import CmuxNextDesign
import CoreGraphics

/// The sidebar's own density (`sidebar.density`, Lawrence 2026-10-14) on top
/// of the app's `appearance.density` tokens. Every sidebar size that depends
/// on it reads this one place: the list (`SidebarLayoutMetrics.standard`), the
/// pinned and other top or bottom bands (`SidebarRegionMetrics.standard`) and
/// the row padding (`SidebarStyle.horizontalInset`).
///
/// Compact (the default) and expanded keep the app tokens exactly. Comfortable
/// keeps one line per row and adds height and room, sized like the medium
/// sidebar size of the system's own sidebars (28 pt rows against the small
/// size's 24 pt), at the app's compact density:
///
/// | token                  | compact | comfortable | step              |
/// |------------------------|---------|-------------|-------------------|
/// | row, tab row, group    | 24      | 28          | + `space2`        |
/// | machine/section header | 22      | 26          | + `space2`        |
/// | row with a detail line | 36      | 40          | + `space2`        |
/// | horizontal inset       | 6       | 8           | `space3`→`space4` |
/// | section gap            | 8       | 12          | `space4`→`space5` |
/// | list top padding       | 4       | 6           | `space2`→`space3` |
/// | group bottom padding   | 6       | 8           | `space3`→`space4` |
///
/// Row title and detail text size and weight do not change (Interface Size
/// owns the text size); a group header's name keeps its existing rule and
/// follows its bar (`SidebarStyle.groupHeaderFont`: 11 pt on the 24 pt row,
/// 12 pt on the 28 pt row). Row spacing stays `space1` so selection fills
/// keep their rhythm. Values are read at layout time, never cached, so a
/// change applies live.
enum SidebarDensityTokens {
    static var density: SidebarDensity { DesignSettings.shared.sidebarSections.density }
    static var isComfortable: Bool { density == .comfortable }
    /// The extra height of a comfortable row or header.
    private static var extra: CGFloat { isComfortable ? Metrics.space2 : 0 }

    /// A one-line workspace row, tab row, group header or band row.
    static var rowHeight: CGFloat { Metrics.sidebarRowHeight + extra }
    /// A workspace row with one detail line (the step per extra line is the app's).
    static var rowHeightWithSubtitle: CGFloat { Metrics.sidebarRowHeightWithSubtitle + extra }
    /// A machine or section header in the list, and a band's header.
    static var headerHeight: CGFloat { Metrics.sidebarHeaderHeight + extra }
    /// Rows inset from the sidebar edge, and their content from the row edge.
    static var horizontalInset: CGFloat { isComfortable ? Metrics.space4 : Metrics.space3 }
    static var sectionSpacing: CGFloat { isComfortable ? Metrics.space5 : Metrics.space4 }
    static var topPadding: CGFloat { isComfortable ? Metrics.space3 : Metrics.space2 }
    static var groupBottomPadding: CGFloat { isComfortable ? Metrics.space4 : Metrics.space3 }
}
