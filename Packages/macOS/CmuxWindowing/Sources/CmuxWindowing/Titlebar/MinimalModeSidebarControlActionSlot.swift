/// The fixed set of buttons rendered in the minimal-mode titlebar control
/// region, in left-to-right order.
///
/// The `Int` raw value is the button's positional index, so `allCases` doubles
/// as the ordered layout and `init(rawValue:)` resolves a hit-tested index back
/// to its action. Each slot carries the stable identifiers and telemetry name
/// the app uses to wire the button; the user-facing accessibility *label* is
/// resolved app-side via `String(localized:)` so localized (e.g. Japanese)
/// strings come from the app bundle, not this package.
public enum MinimalModeSidebarControlActionSlot: Int, CaseIterable {
    case toggleSidebar
    case showNotifications
    case newTab
    case focusHistoryBack
    case focusHistoryForward

    /// The accessibility/automation identifier set on the button. Stable wire
    /// string consumed by UI tests; never localized.
    public var accessibilityIdentifier: String {
        switch self {
        case .toggleSidebar:
            return "titlebarControl.toggleSidebar"
        case .showNotifications:
            return "titlebarControl.showNotifications"
        case .newTab:
            return "titlebarControl.newTab"
        case .focusHistoryBack:
            return "titlebarControl.focusHistoryBack"
        case .focusHistoryForward:
            return "titlebarControl.focusHistoryForward"
        }
    }

    /// Stable name used in telemetry payloads. Never localized.
    public var debugName: String {
        switch self {
        case .toggleSidebar:
            return "toggleSidebar"
        case .showNotifications:
            return "showNotifications"
        case .newTab:
            return "newTab"
        case .focusHistoryBack:
            return "focusHistoryBack"
        case .focusHistoryForward:
            return "focusHistoryForward"
        }
    }

    /// Whether a right-click on this button should be allowed to open a context
    /// menu rather than being consumed as a primary action.
    public var acceptsContextMenu: Bool {
        switch self {
        case .toggleSidebar, .newTab, .focusHistoryBack, .focusHistoryForward:
            return true
        case .showNotifications:
            return false
        }
    }
}
