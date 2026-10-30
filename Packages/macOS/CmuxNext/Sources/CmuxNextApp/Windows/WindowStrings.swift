import Foundation

/// Localized strings for windows. Keys live in Resources/Windows.xcstrings.
enum WindowStrings {
    /// Palette label of a window without a workspace name ("Window 2").
    static func windowNumber(_ number: Int) -> String {
        String(format: String(localized: "window.target.number", defaultValue: "Window %lld", table: "Windows", bundle: .module), number)
    }

    /// Titlebar badge of an incognito window.
    static var incognitoBadge: String {
        String(localized: "window.incognito.badge", defaultValue: "Incognito", table: "Windows", bundle: .module)
    }

    static var incognitoHelp: String {
        String(localized: "window.incognito.help",
               defaultValue: "Incognito window. Its browser data is deleted when the last incognito window closes.",
               table: "Windows", bundle: .module)
    }

    /// Toast when the home daemon refused to record a connected machine in the session registry:
    /// the next launch does not restore it. `reason` is the daemon's refusal.
    static func machineNotSavedForRestore(machine: String?, reason: String) -> String {
        guard let machine, !machine.isEmpty else {
            return String(format: String(localized: "window.restore.machineNotSaved.unnamed",
                                         defaultValue: "This machine was not saved for restore: %@", table: "Windows", bundle: .module),
                          reason)
        }
        return String(format: String(localized: "window.restore.machineNotSaved",
                                     defaultValue: "%1$@ was not saved for restore: %2$@", table: "Windows", bundle: .module),
                      machine, reason)
    }
}
