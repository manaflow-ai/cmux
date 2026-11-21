nonisolated extension ToolbarPosition {
    /// Whether a pane's tab strip goes between a browser's toolbar on this edge and its page (`tabs.barOrder`, R109):
    /// both on one edge, and the order puts the strip on the page's side (tab bar below a top toolbar, above a bottom
    /// one). The pane then pins its strip to the browser's header band.
    ///
    /// ```swift
    /// ToolbarPosition.top.holdsStripBand(strip: .top, order: .belowToolbar)  // true
    /// ToolbarPosition.top.holdsStripBand(strip: .top, order: .aboveToolbar)  // false
    /// ```
    ///
    /// - Parameters:
    ///   - strip: The edge the tab strip sits on (`tabs.barPosition`).
    ///   - order: The strip's order beside the toolbar (`tabs.barOrder`).
    /// - Returns: True when the strip sits in the browser's band.
    public func holdsStripBand(strip: TabBarPosition, order: TabBarOrder) -> Bool {
        switch (strip, self) {
        case (.top, .top): order == .belowToolbar
        case (.bottom, .bottom): order == .aboveToolbar
        default: false
        }
    }
}
