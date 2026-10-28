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

/// What the daemon pushes about a terminal's shell (OSC 133 marks of its shell integration and the daemon's
/// `extra.activity`), and what a close may read from it without asking the terminal (Lawrence 2026-10-28,
/// shortcut spam: a close decides in the person's own turn).
///
/// Limits (a close's undo toast still reads what ran, after the close): a nested shell with its own OSC 133 marks
/// (ssh or `docker exec` into an integrated shell) reports its prompt, so the tab reads idle while ssh runs; it then
/// closes without the question (its terminal survives the reap grace, and Undo brings it back). A command typed a
/// moment before the press may not be pushed yet. A shell replaced without integration (`exec bash`) can leave a
/// stale running command, which asks once. A daemon check of the PTY's foreground leader against the shell would
/// close these (cmux-tui follow-up).
public enum PushedShellState: Equatable, Sendable {
    /// At its prompt: nothing runs in the foreground.
    case idle
    /// A command runs (work in progress, or a program that uses the terminal: vim, less, ssh, a REPL).
    case busy
    /// No state reported (a shell without integration, a program spawned directly, a terminal just made).
    case unknown

    /// `tab`'s pushed state (``TabModel/commandSinceMs``, ``TabModel/commandInUse``, ``TabModel/promptSinceMs``).
    @MainActor
    public init(_ tab: TabModel) {
        if tab.commandSinceMs != nil || tab.commandInUse { self = .busy } else { self = tab.promptSinceMs != nil ? .idle : .unknown }
    }

    /// What `terminals` run from their pushed states alone: nil for an idle one, ``RunningPrograms/unnamed`` for a
    /// running command (its name comes from a read), or nil overall when one reports no state.
    @MainActor
    public static func programs(_ terminals: [TabModel]) -> RunningPrograms? {
        var programs: RunningPrograms = [:]
        for tab in terminals {
            switch PushedShellState(tab) {
            case .idle: programs[tab.surface] = .some(nil)
            case .busy: programs[tab.surface] = .some(RunningPrograms.unnamed)
            case .unknown: return nil
            }
        }
        return programs
    }
}
