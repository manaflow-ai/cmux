public import CoreGraphics

extension Metrics {
    /// Distance from a pane's trailing edge to the center of its last control: the tab bar's ⋮
    /// (`PaneToolbarView`) and the browser toolbar's ⋮ (More) share it, one column.
    ///
    /// Lawrence msg 19627: "the three vertical dots, there are 2 of them, and they are different
    /// sizes". The column is the browser toolbar's (its pill-line inset, ``paneChromeInset``, plus
    /// half a toolbar button), never inside the tab bar ⋮'s own corner gap (its button centered in the
    /// strip's height, as far from the trailing edge as from the top).
    public static var paneTrailingControlCenter: CGFloat {
        let toolbar = paneChromeInset + tokens.toolbarButtonSize / 2
        let side = TitlebarBandButton.side
        let strip = max(0, ((tabStripHeight - side) / 2).rounded()) + side / 2
        return max(toolbar, strip)
    }
}
