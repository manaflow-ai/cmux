import Foundation

@MainActor
struct StandardQuitConfirmationDefaultsSnapshot {
    private let confirmQuit: Any?
    private let warnBeforeQuitShortcut: Any?

    static func capture() -> Self {
        let defaults = UserDefaults.standard
        return Self(
            confirmQuit: defaults.object(forKey: "confirmQuit"),
            warnBeforeQuitShortcut: defaults.object(forKey: "warnBeforeQuitShortcut")
        )
    }

    func restore() {
        let defaults = UserDefaults.standard
        if let confirmQuit {
            defaults.set(confirmQuit, forKey: "confirmQuit")
        } else {
            defaults.removeObject(forKey: "confirmQuit")
        }

        if let warnBeforeQuitShortcut {
            defaults.set(warnBeforeQuitShortcut, forKey: "warnBeforeQuitShortcut")
        } else {
            defaults.removeObject(forKey: "warnBeforeQuitShortcut")
        }
    }
}
