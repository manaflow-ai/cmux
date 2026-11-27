// Hover-reveal settings of window chrome (R83, R120), driven through
// HoverReveal.

/// `window.titlebarButtons` (R83): when the title bar's buttons (Back,
/// Forward, and later ones; never the sidebar toggle) show.
public nonisolated enum TitlebarButtonsMode: String, Sendable, CaseIterable, Codable {
    /// Hidden until the pointer is over the title bar row, then they fade
    /// in, in place (the default).
    case hover
    /// Always shown.
    case always
}

/// `sidebar.spacesVisibility` (cx-5k3r, Lawrence 2026-10-08: "by default,
/// spaces should only be visible when i hover on sidebar. same as all the
/// other buttons"): when the sidebar's spaces strip shows.
public nonisolated enum SpacesVisibilityMode: String, Sendable, CaseIterable, Codable {
    /// Only while the sidebar is hovered (the default), with the sidebar's
    /// other hover chrome.
    case hover
    /// Always shown.
    case always
}

/// `tabs.plusButton` (R120): when each tab bar's plus button shows.
public nonisolated enum PlusButtonMode: String, Sendable, CaseIterable, Codable {
    /// Only while the tab bar is hovered (the default).
    case hover
    /// Always shown.
    case always
}
