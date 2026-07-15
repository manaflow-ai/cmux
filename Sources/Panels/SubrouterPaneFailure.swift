import Foundation

/// User-presentable failure categories for the Subrouter pane.
enum SubrouterPaneFailure: Equatable, Sendable {
    case codexSignInRequired
    case executableUnavailable
    case unavailable

    init(error: any Error) {
        if let error = error as? SubrouterAccountServiceError {
            switch error {
            case .executableUnavailable:
                self = .executableUnavailable
            case .commandFailed(_, _, let message)
                where message.localizedCaseInsensitiveContains("auth.json")
                    || message.localizedCaseInsensitiveContains("codex login"):
                self = .codexSignInRequired
            case .launchFailed, .commandFailed, .malformedAccount:
                self = .unavailable
            }
            return
        }
        self = .unavailable
    }

    var message: String {
        switch self {
        case .executableUnavailable:
            return String(
                localized: "subrouterPane.error.executableUnavailable",
                defaultValue: "The bundled Subrouter executable is missing."
            )
        case .codexSignInRequired:
            return String(
                localized: "subrouterPane.error.codexSignInRequired",
                defaultValue: "Sign in with `codex login`, then try again."
            )
        case .unavailable:
            return String(
                localized: "subrouterPane.error.unavailable",
                defaultValue: "Subrouter failed. Run `cmux sr status` for details."
            )
        }
    }
}
