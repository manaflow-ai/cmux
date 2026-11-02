public import CmuxNextDaemon

/// Each asked live terminal's foreground program (nil: its shell only, or no
/// answer in time). A terminal missing from it was not asked.
public typealias RunningPrograms = [SurfaceID: String?]

extension Dictionary where Key == SurfaceID, Value == String? {
    /// The programs, unique and sorted.
    public var programNames: [String] { Set(values.compactMap { $0 }).sorted() }

    /// Whether every terminal in `tabs` was asked, so its answer can stand in for asking again.
    public func covers(_ tabs: [TabModel]) -> Bool { tabs.allSatisfy { keys.contains($0.surface) } }
}

/// The one question a close of live terminals can ask (`TabCloseGuard`, #17501): an agent at work in one, else
/// foreground programs.
public enum CloseWarning: Equatable, Sendable {
    /// The agent working in a closing terminal (the first, if several).
    case agent(String)
    /// Foreground programs in the closing terminals, unique and sorted.
    case programs([String])

    /// The question for these closing terminals, or nil to close at once.
    public static func of(agents: [String], programs: [String], warnTab: Bool, warnAgent: Bool) -> CloseWarning? {
        if warnAgent, let agent = agents.first { return .agent(agent) }
        if warnTab, !programs.isEmpty { return .programs(programs) }
        return nil
    }
}

extension DaemonService {
    /// Each live terminal of `tabs`' foreground program, or nil when it runs none: one bounded read (1 s) per terminal,
    /// concurrent. One gesture asks once and passes this on (a close's question, then its undo toast decision).
    /// `unanswered`: what a terminal that gave no answer (or every terminal, with no connection) counts as running;
    /// nil counts it as running none.
    @MainActor public func runningPrograms(of tabs: [TabModel], unanswered: (@MainActor (TabModel) -> String)? = nil) async -> RunningPrograms {
        let terminals = tabs.filter { $0.kind == .pty && !$0.dead }
        // No connection: nothing was asked (the base answer, an empty map), unless no answer counts as a program.
        guard let connection, !terminals.isEmpty else {
            guard let unanswered else { return [:] }
            return Dictionary(uniqueKeysWithValues: terminals.map { ($0.surface, .some(unanswered($0))) })
        }
        await closeReadStarts() // a test may hold the read here (debug.close.hold, DEBUG and bench builds)
        let fallback = Dictionary(uniqueKeysWithValues: terminals.map { ($0.surface, unanswered?($0)) })
        return await withTaskGroup(of: (SurfaceID, String?).self) { group in
            for tab in terminals {
                let surface = tab.surface, otherwise = fallback[surface] ?? nil
                group.addTask { (surface, await connection.readProcessInfo(surface, timeout: .seconds(1)).map(\.runningProgram) ?? otherwise) }
            }
            var programs: RunningPrograms = [:]
            for await (surface, program) in group { programs[surface] = .some(program) }
            return programs
        }
    }
}
