import Foundation

/// Reasons the File menu's Computer Use actions give. Keys live in
/// Resources/MiscHandlers.xcstrings (en, ja).
enum ComputerUseSessionStrings {
    static var noLiveSession: String {
        String(localized: "handlers.computerUse.noLiveSession", defaultValue: "No Computer Use session is running.",
               table: "MiscHandlers", bundle: .module)
    }
    static var noTarget: String {
        String(localized: "handlers.computerUse.noTarget", defaultValue: "The Computer Use session has not used an app yet, or that app quit.",
               table: "MiscHandlers", bundle: .module)
    }
    static var noCallingTerminal: String {
        String(localized: "handlers.computerUse.noCallingTerminal",
               defaultValue: "cmux cannot find the terminal that started this Computer Use session.",
               table: "MiscHandlers", bundle: .module)
    }
    static var off: String {
        String(localized: "handlers.computerUse.off", defaultValue: "Computer Use is off. Turn it on in Settings > Computer Use.",
               table: "MiscHandlers", bundle: .module)
    }
    static var disabledByPolicy: String {
        String(localized: "handlers.computerUse.disabledByPolicy", defaultValue: "Your organization turned Computer Use off.",
               table: "MiscHandlers", bundle: .module)
    }
    static var helperNotRunning: String {
        String(localized: "handlers.computerUse.helperNotRunning", defaultValue: "The Computer Use helper is not running.",
               table: "MiscHandlers", bundle: .module)
    }
    /// The helper had exited without its exit being noticed; it is starting again.
    static var helperRestarting: String {
        String(localized: "handlers.computerUse.helperRestarting",
               defaultValue: "The Computer Use helper had stopped, so cmux is starting it again. Try again in a moment.",
               table: "MiscHandlers", bundle: .module)
    }
    static var hostUnreachable: String {
        String(localized: "handlers.computerUse.hostUnreachable", defaultValue: "The Computer Use helper did not answer.",
               table: "MiscHandlers", bundle: .module)
    }
    /// The helper refused the request; `message` is its error code.
    static func hostRefused(_ message: String) -> String {
        String(format: String(localized: "handlers.computerUse.hostRefused", defaultValue: "The Computer Use helper refused: %@",
                              table: "MiscHandlers", bundle: .module), message)
    }

    /// Why no helper answers, from the phase `computer_use.status` reports.
    static func notRunning(_ phase: ComputerUseSetup.Phase) -> String {
        switch phase {
        case .off: off
        case .disabledByPolicy: disabledByPolicy
        case .unavailable, .starting, .failed, .ready, .versionMismatch: helperNotRunning
        }
    }
}
