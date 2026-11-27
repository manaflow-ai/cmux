import Foundation

/// Failures from a local tmux Settings action, localized by the owning package.
public enum LocalTmuxSettingsActionError: LocalizedError, Sendable {
    /// The host cannot perform local tmux actions.
    case unavailable
    /// The CLI returned a malformed session list.
    case invalidResponse
    /// The app's bundled CLI is absent.
    case cliMissing
    /// The CLI failed to launch or exited unsuccessfully.
    case commandFailed

    /// User-facing explanation from the Settings localization catalog.
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "settings.terminal.localTmux.unavailable", defaultValue: "Open a workspace and try again.", bundle: .module)
        case .invalidResponse:
            return String(localized: "settings.terminal.localTmux.invalidResponse", defaultValue: "Could not update saved sessions. Try again.", bundle: .module)
        case .cliMissing:
            return String(localized: "settings.terminal.localTmux.cliMissing", defaultValue: "Session persistence is unavailable. Reinstall cmux and try again.", bundle: .module)
        case .commandFailed:
            return String(localized: "settings.terminal.localTmux.commandFailed", defaultValue: "Could not update saved sessions. Try again.", bundle: .module)
        }
    }
}
