public import CoreGraphics

/// `appearance.sidebarSurface` in cmux.json (Leo 2026-10-12): whether the
/// sidebar has a surface of its own beside the main pane.
///
/// - `same` (the default): the sidebar draws the main pane's surface. The
///   chrome around the curved main pane takes no shade; the pane outlines
///   and the sidebar's edge line keep them apart. Over glass both share it.
/// - `separate`: the look before: the sidebar, the gutter and the titlebar
///   are shaded darker than the main pane, so the pane reads as a card.
public nonisolated enum SidebarSurface: String, Sendable, CaseIterable, Codable {
    case same
    case separate

    /// Share of the separate shade a shared surface keeps when no line draws
    /// anywhere (`appearance.borders` none): with no pane outline or edge
    /// line, a faint tonal step is the only thing that parts the sidebar
    /// from the main pane.
    public static let borderlessStep: CGFloat = 0.35

    /// Black's alpha over the chrome around the main pane.
    ///
    /// - Parameters:
    ///   - separateShade: The shade of the separate look in this theme.
    ///   - drawsLines: Whether borders and hairlines draw (`Borders`).
    public func chromeShade(separateShade: CGFloat, drawsLines: Bool) -> CGFloat {
        switch self {
        case .separate: separateShade
        case .same: drawsLines ? 0 : separateShade * Self.borderlessStep
        }
    }
}
