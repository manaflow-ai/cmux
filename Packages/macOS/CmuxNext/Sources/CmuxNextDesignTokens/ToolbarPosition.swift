/// `browser.toolbarPosition`: the edge of a browser or Markdown viewer pane
/// its omnibar row (back, forward, reload, the address bar and its buttons)
/// sits on. With the tab bar on the same edge, `tabs.barOrder` stacks the two.
public nonisolated enum ToolbarPosition: String, Sendable, CaseIterable, Codable {
    /// Above the page (the default).
    case top
    /// Below the page; the toolbar's popups (suggestions, menus, bubbles)
    /// open upward and the find and permission bars sit at the page's bottom.
    case bottom
}
