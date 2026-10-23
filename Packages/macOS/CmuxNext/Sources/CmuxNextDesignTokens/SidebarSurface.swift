public import CoreGraphics

/// `appearance.sidebarSurface` in cmux.json (Leo 2026-10-12): whether the
/// sidebar has a surface of its own beside the main pane.
///
/// - `same` (the default): the sidebar draws the main pane's surface, with
///   no shade of its own, whether or not a line parts them (Lawrence
///   2026-10-19: "it should just have a border on the sidebar, not a
///   different color"; the window styles turn on the sidebar's edge line).
///   Over glass both share it.
/// - `separate`: the sidebar, the gutter and the titlebar are shaded darker
///   than the main pane, so the pane reads as a card.
public nonisolated enum SidebarSurface: String, Sendable, CaseIterable, Codable {
    case same
    case separate

    /// Share of the separate shade a shared surface keeps when no line parts
    /// the sidebar from the main pane. 0: the shared surface is one color
    /// (the faint tonal step of 2026-10-12 read as a different sidebar
    /// color); `chrome.mainPane.borderlessStep` can still set one.
    public static let borderlessStep: CGFloat = 0

    /// Black's alpha over the chrome around the main pane.
    ///
    /// - Parameters:
    ///   - separateShade: The shade of the separate look in this theme.
    ///   - lineSeparates: Whether a drawn line parts the sidebar from the
    ///     main pane (a pane outline or the sidebar's edge line).
    ///   - borderlessStep: The share kept without a line (`ChromeStyle`).
    public func chromeShade(separateShade: CGFloat, lineSeparates: Bool,
                            borderlessStep: CGFloat = Self.borderlessStep) -> CGFloat {
        switch self {
        case .separate: separateShade
        case .same: lineSeparates ? 0 : separateShade * borderlessStep
        }
    }
}
