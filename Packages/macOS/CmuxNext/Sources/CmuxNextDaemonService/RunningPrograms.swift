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
