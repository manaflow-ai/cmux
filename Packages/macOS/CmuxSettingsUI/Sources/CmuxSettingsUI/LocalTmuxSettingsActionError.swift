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
            return String(localized: "settings.terminal.localTmux.unavailable", defaultValue: "Local session persistence is unavailable in this settings host.", bundle: .module)
        case .invalidResponse:
            return String(localized: "settings.terminal.localTmux.invalidResponse", defaultValue: "cmux local-tmux returned an invalid session list.", bundle: .module)
        case .cliMissing:
            return String(localized: "settings.terminal.localTmux.cliMissing", defaultValue: "The bundled cmux command-line tool could not be found.", bundle: .module)
        case .commandFailed:
            return String(localized: "settings.terminal.localTmux.commandFailed", defaultValue: "cmux local-tmux could not complete the requested action.", bundle: .module)
        }
    }
}
