import CmuxNextActions
import CmuxNextSettings

/// A quit request that names more than one choice.
struct QuitArgumentConflict: Error, Equatable {
    static let reason = "quit takes one of --keep-sessions, --end-sessions and --end-everything"
}

/// The App's side of the quit rules (`QuitRules`, CmuxNextDaemonService):
/// the quit action's origin and `app.quitBehavior` as the remembered choice.
enum QuitPolicy {
    /// The origin of a `quit` action run: its flags, else scripted for a
    /// capturing caller (control socket, CLI), else interactive.
    static func origin(for invocation: ActionInvocation, scripted: Bool) throws(QuitArgumentConflict) -> QuitOrigin {
        let flags: [(String, QuitSessionsChoice)] = [("keepSessions", .keep), ("endSessions", .endKeepLayout), ("endEverything", .endEverything)]
        let chosen = flags.filter { invocation[$0.0]?.boolValue == true }.map(\.1)
        guard chosen.count <= 1 else { throw QuitArgumentConflict() }
        if let choice = chosen.first { return .explicit(choice) }
        return scripted ? .scripted : .interactive
    }

    /// `QuitRules.decide` with the setting's remembered choice.
    static func decide(_ origin: QuitOrigin, behavior: QuitBehavior) -> QuitSessionsChoice {
        let remembered: QuitSessionsChoice = switch behavior {
        case .keep: .keep
        case .endKeepLayout: .endKeepLayout
        case .endEverything: .endEverything
        }
        return QuitRules.decide(origin, remembered: remembered)
    }
}
