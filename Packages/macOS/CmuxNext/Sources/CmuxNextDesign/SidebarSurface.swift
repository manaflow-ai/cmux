public import CoreGraphics

/// `appearance.sidebarSurface` in cmux.json (Leo 2026-10-12): whether the
/// sidebar has a surface of its own beside the main pane.
///
/// - `same` (the default): the sidebar draws the main pane's surface. The
///   chrome around the curved main pane takes no shade while a line parts
///   them (the pane outlines of the `borders` separation, or the sidebar's
///   edge line with `sidebar.border`); without one it keeps a faint step.
///   Over glass both share it.
/// - `separate`: the sidebar, the gutter and the titlebar are shaded darker
///   than the main pane, so the pane reads as a card.
public nonisolated enum SidebarSurface: String, Sendable, CaseIterable, Codable {
    case same
    case separate

    /// Share of the separate shade a shared surface keeps when no line parts
    /// the sidebar from the main pane: no pane outline (`layout.paneSeparation`
    /// cards, dividers or none, or `appearance.borders` none) and no sidebar
    /// edge line. A faint tonal step is then the only thing between them.
    public static let borderlessStep: CGFloat = 0.35

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
