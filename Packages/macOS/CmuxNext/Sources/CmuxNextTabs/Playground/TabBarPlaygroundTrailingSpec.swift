import CoreGraphics
import CmuxNextDesign
import CmuxNextIcons

/// DEV and NIGHTLY (the Debug menu): one layout of a browser pane's two trailing control groups (Lawrence msg 19627): the
/// tab bar's (+, ⌄, ⋮) and the browser toolbar's under it (Extensions, DevTools, ⋮).
struct TabBarPlaygroundTrailingSpec {
    /// The tab bar's ⋮ glyph, or nil for none (its rows move to the toolbar's ⋮).
    var tabBarMore: IconName? = OverflowButton.glyph
    /// The toolbar's ⋮ glyph, or nil for none (its rows move to the tab bar's ⋮).
    var toolbarMore: IconName? = OverflowButton.glyph
    /// Each ⋮'s glyph side: the tab bar's, the toolbar's.
    var tabBarMoreSize: CGFloat = OverflowButton.glyphSize
    var toolbarMoreSize: CGFloat = OverflowButton.glyphSize
    /// The toolbar's other icons' side, and its buttons' side.
    var toolbarIconSize: CGFloat = Metrics.tokens.resolve(compact: 20, comfortable: 22)
    var toolbarButtonSide: CGFloat = Metrics.tokens.toolbarButtonSize
    /// The tab bar's buttons' side.
    var tabBarButtonSide: CGFloat = TitlebarBandButton.side
    /// Distance from the pane's edge to each last control's center: the tab bar's, the toolbar's.
    var tabBarColumn: CGFloat = Metrics.paneTrailingControlCenter
    var toolbarColumn: CGFloat = Metrics.paneTrailingControlCenter
    /// Lay the toolbar's buttons in the tab bar's columns, one under each tab bar control.
    var sharesColumns = false

    /// The shipped layout, today: one ⋮ glyph and size, one column.
    static var shipped: TabBarPlaygroundTrailingSpec { TabBarPlaygroundTrailingSpec() }

    /// The layout before the fix: the toolbar's own ⋮ glyph at its icon size, each row's own inset.
    static var before: TabBarPlaygroundTrailingSpec {
        var spec = TabBarPlaygroundTrailingSpec()
        spec.toolbarMore = .browserToolbarMore
        spec.toolbarMoreSize = spec.toolbarIconSize
        let side = TitlebarBandButton.side
        spec.tabBarColumn = max(0, ((Metrics.tabStripHeight - side) / 2).rounded()) + side / 2
        spec.toolbarColumn = Metrics.paneChromeInset + spec.toolbarButtonSide / 2
        return spec
    }
}
