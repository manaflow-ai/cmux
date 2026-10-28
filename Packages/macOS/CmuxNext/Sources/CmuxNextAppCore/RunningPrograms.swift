public import CmuxNextDaemon

/// Each asked live terminal's foreground program (nil: its shell only, or no
/// answer in time). A terminal missing from it was not asked.
public typealias RunningPrograms = [SurfaceID: String?]

extension Dictionary where Key == SurfaceID, Value == String? {
    /// The name of a command that runs (pushed state) before a read named its program.
    public static var unnamed: String { "" }

    /// The programs, unique and sorted (named ones only).
    public var programNames: [String] { Set(values.compactMap { $0 }.filter { !$0.isEmpty }).sorted() }

    /// Whether a command runs whose program is not named yet.
    public var hasUnnamedProgram: Bool { values.contains { $0 == Self.unnamed } }

    /// Whether every terminal in `tabs` was asked, so its answer can stand in for asking again.
    @MainActor
    public func covers(_ tabs: [TabModel]) -> Bool { tabs.allSatisfy { keys.contains($0.surface) } }
}

/// What the daemon pushes about a terminal's shell, and what a close may read from it without asking the terminal
/// (Lawrence 2026-10-28, shortcut spam: a close decides in the person's own turn).
///
/// Idle comes only from the daemon's `extra.shell_idle` (``TabModel/shellIdleSinceMs``, cmux-tui
/// cp/daemon-foreground-state): the PTY's foreground group is the terminal's own interactive shell, at its prompt,
/// and no input reached the daemon since that prompt; a nested shell over ssh, `exec sh`, a script and input that may
/// bypass the daemon never read idle. A key typed into the window after the app applied that state
/// (`typedSince`) may have started a command the daemon has not reported yet: then the state is unknown. Busy comes
/// from a running command (``TabModel/commandSinceMs``, ``TabModel/commandInUse``). Everything else is unknown, and a
/// close reads the terminal (or asks). A daemon without `shell_idle` never reads idle, so nothing closes unasked.
public enum PushedShellState: Equatable, Sendable {
    /// At its prompt: nothing runs in the foreground.
    case idle
    /// A command runs (work in progress, or a program that uses the terminal: vim, less, ssh, a REPL).
    case busy
    /// No state reported (a shell without integration, a program spawned directly, a terminal just made).
    case unknown

    /// `tab`'s pushed state (``TabModel/commandSinceMs``, ``TabModel/commandInUse``, ``TabModel/promptSinceMs``).
    /// `typedSince`: whether a key was typed into the tab's window after `uptime` (nil: none known).
    @MainActor
    public init(_ tab: TabModel, typedSince: (TimeInterval) -> Bool = { _ in false }) {
        if tab.commandSinceMs != nil || tab.commandInUse { self = .busy; return }
        guard tab.shellIdleSinceMs != nil, let seen = tab.shellIdleSeenAt, !typedSince(seen) else { self = .unknown; return }
        self = .idle
    }

    /// What `terminals` run from their pushed states alone: nil for an idle one, ``RunningPrograms/unnamed`` for a
    /// running command (its name comes from a read), or nil overall when one reports no state.
    @MainActor
    public static func programs(_ terminals: [TabModel], typedSince: (TimeInterval) -> Bool = { _ in false }) -> RunningPrograms? {
        var programs: RunningPrograms = [:]
        for tab in terminals {
            switch PushedShellState(tab, typedSince: typedSince) {
            case .idle: programs[tab.surface] = .some(nil)
            case .busy: programs[tab.surface] = .some(RunningPrograms.unnamed)
            case .unknown: return nil
            }
        }
        return programs
    }
}
