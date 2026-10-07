/// What the key window does with an action run instead of its handler
/// (`ActionRegistry.keyWindowRoute`, asked before availability,
/// confirmation and the handler, and by menu validation). The App answers
/// for windows of their own (Debug Settings, the App Store, onboarding):
/// their close shortcuts close them, and actions on main window content do
/// not reach the main window behind them.
public enum KeyWindowRoute {
    /// Runs `work` instead of the handler; menu items stay enabled.
    case run(@MainActor () -> Void)
    /// Nothing runs, the menu item is disabled, and a run is refused with
    /// `reason` (the palette shows it).
    case disabled(reason: String)

    /// Runs the route. Returns whether something ran.
    @MainActor
    func perform(refuse: (String) -> Void) -> Bool {
        switch self {
        case .run(let work):
            work()
            return true
        case .disabled(let reason):
            refuse(reason)
            return false
        }
    }

    /// Whether a menu item for the action is enabled.
    var enablesMenuItem: Bool {
        if case .run = self { return true }
        return false
    }
}
