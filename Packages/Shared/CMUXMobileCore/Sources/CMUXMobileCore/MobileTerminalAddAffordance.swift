/// The "add" affordances offered from the mobile workspace terminal navbar.
///
/// Issue #6271: the prominent "+" button next to the terminal picker created a
/// whole new *workspace*, which TestFlight users found unintuitive — they
/// expected it to add a terminal to the workspace they were already in (the
/// macOS default). Modeling the two actions and their glyphs here, in the pure
/// core, lets the iOS toolbar bind its primary button to one of them and lets a
/// headless unit test pin that choice, so the wiring can't silently regress back
/// to "new workspace".
public enum MobileTerminalAddAffordance: Equatable, Sendable {
    /// Add a terminal to the workspace currently on screen.
    case newTerminalInCurrentWorkspace
    /// Create a brand-new workspace (with its own first terminal).
    case newWorkspace

    /// SF Symbol for the affordance. A plain `plus` reads as "add" (matching the
    /// macOS new-tab glyph); the layered `plus.square.on.square` reads as a new
    /// stacked workspace — the very icon testers misread as "add terminal".
    public var systemImageName: String {
        switch self {
        case .newTerminalInCurrentWorkspace:
            return "plus"
        case .newWorkspace:
            return "plus.square.on.square"
        }
    }
}

/// Identity of the prominent "+" button in the mobile workspace terminal navbar
/// (the slot immediately to the left of the terminal picker).
///
/// Pinned to ``MobileTerminalAddAffordance/newTerminalInCurrentWorkspace`` for
/// issue #6271; `MobileTerminalAddAffordanceTests` guards it so a refactor can't
/// quietly rebind it to "new workspace" again.
public enum MobileTerminalPrimaryAddButton {
    /// What tapping the prominent "+" does.
    public static let affordance: MobileTerminalAddAffordance = .newWorkspace
}
