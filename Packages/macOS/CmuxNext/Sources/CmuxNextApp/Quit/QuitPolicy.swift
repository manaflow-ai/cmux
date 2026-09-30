import CmuxNextActions
import CmuxNextSettings

/// What happens to the local terminals when cmux quits. They run in the
/// local cmux-tui daemon, which outlives the app (cmux-tui-contract.md 1.5).
enum QuitSessionsChoice: String, Equatable, Sendable {
    /// Leave every local terminal and the daemon running.
    case keep
    /// End every local terminal and stop the local daemon
    /// (`shutdown-daemon end_terminals`).
    case end
}

/// Who asked to quit.
enum QuitOrigin: Equatable, Sendable {
    /// Cmd-Q, the Quit menu item or the Dock's Quit: may show the sheet.
    case interactive
    /// "Quit and Keep Sessions", "Quit and End Sessions", or `cmux app quit`
    /// with `--keep-sessions` / `--end-sessions`: runs as asked.
    case explicit(QuitSessionsChoice)
    /// `cmux app quit` (or `action.run quit`) with no flag: follows the
    /// setting and never waits on a sheet.
    case scripted
    /// Shut down, restart or log out: never asks, never ends terminals
    /// (the system ends them).
    case powerOff
}

/// One running program in a terminal that Quit keeps.
struct QuitProgram: Equatable, Sendable {
    var name: String
    /// CPU time of the terminal's processes other than its shell.
    var cpuNanos: UInt64
}

/// The local state the quit decision reads.
struct QuitFacts: Equatable, Sendable {
    /// Local terminals outside incognito windows (they outlive the app).
    var terminals: Int
    /// Those terminals' foreground programs other than the shell.
    var programs: [QuitProgram]
    /// Programs running in incognito windows' terminals, which always end.
    var incognitoPrograms: [String]
    /// Any Cloud or SSH session is known (never ended from the sheet).
    var remoteSessions: Bool

    static let none = QuitFacts(terminals: 0, programs: [], incognitoPrograms: [], remoteSessions: false)
}

/// The quit sheet's content.
struct QuitPrompt: Equatable, Sendable {
    var terminals: Int
    var runningPrograms: Int
    /// The busiest program names (most CPU first), at most `QuitPolicy.busiestLimit`.
    var busiest: [String]
    var incognitoPrograms: [String]
    var remoteSessions: Bool
    /// False when only incognito terminals are at stake: the sheet then
    /// offers Quit and Cancel (the incognito close confirmation).
    var offersSessionChoice: Bool
    /// The button Return presses.
    var defaultChoice: QuitSessionsChoice
}

enum QuitDecision: Equatable, Sendable {
    case quit(QuitSessionsChoice)
    case ask(QuitPrompt)
}

/// A quit request that names both choices.
struct QuitArgumentConflict: Error, Equatable {
    static let reason = "quit takes --keep-sessions or --end-sessions, not both"
}

/// The quit rules (user decision 2026-09-30), free of AppKit and the daemon.
enum QuitPolicy {
    static let busiestLimit = 3

    /// The origin of a `quit` action run: its flags, else scripted for a
    /// capturing caller (control socket, CLI), else interactive.
    static func origin(for invocation: ActionInvocation, scripted: Bool) throws(QuitArgumentConflict) -> QuitOrigin {
        scripted ? .scripted : .interactive  // not implemented yet
    }

    /// Whether the decision needs `QuitFacts` (read from the daemon).
    static func needsFacts(_ origin: QuitOrigin) -> Bool { origin == .interactive }

    /// Quit at once with a choice, or ask. `facts` is read only for an
    /// interactive quit.
    static func decide(_ origin: QuitOrigin, behavior: QuitBehavior, facts: QuitFacts) -> QuitDecision {
        .quit(.keep)  // not implemented yet
    }

    /// Unique program names, most CPU first (then by name), at most `limit`.
    static func busiest(_ programs: [QuitProgram], limit: Int = busiestLimit) -> [String] {
        []  // not implemented yet
    }

    /// The setting "Don't ask again" writes for a choice.
    static func remembered(_ choice: QuitSessionsChoice) -> QuitBehavior {
        switch choice {
        case .keep: .keep
        case .end: .end
        }
    }
}
