public import CmuxNextDaemon

/// Each asked live terminal's foreground program (nil: its shell only, or no
/// answer in time). A terminal missing from it was not asked.
public typealias RunningPrograms = [SurfaceID: String?]

extension Dictionary where Key == SurfaceID, Value == String? {
    /// The programs, unique and sorted.
    public var programNames: [String] { Set(values.compactMap { $0 }).sorted() }

    /// Whether every terminal in `tabs` was asked, so its answer can stand in for asking again.
    public func covers(_ tabs: [TabModel]) -> Bool { tabs.allSatisfy { keys.contains($0.surface) } }

    /// `answers` as programs: a terminal of `tabs` that gave no answer counts as running what `unanswered` says (nil:
    /// running none).
    @MainActor public init(_ answers: [SurfaceID: ProcessAnswer], of tabs: [TabModel], unanswered: (@MainActor (TabModel) -> String)?) {
        var bySurface: [SurfaceID: TabModel] = [:]
        for tab in tabs where bySurface[tab.surface] == nil { bySurface[tab.surface] = tab }
        var programs: [SurfaceID: String?] = [:]
        for (surface, answer) in answers {
            switch answer {
            case .program(let program): programs[surface] = .some(program)
            case .noAnswer: programs[surface] = .some(bySurface[surface].flatMap { tab in unanswered?(tab) })
            }
        }
        self = programs
    }

    /// The same, a terminal that gave no answer counted as running its tab title when `unansweredRunsTitle` (a person's
    /// close: only a confirmed "no program" closes with no question and no undo toast), else as running none.
    @MainActor public init(_ answers: [SurfaceID: ProcessAnswer], of tabs: [TabModel], unansweredRunsTitle: Bool) {
        if unansweredRunsTitle { self.init(answers, of: tabs, unanswered: { tab in tab.displayTitle }) } else { self.init(answers, of: tabs, unanswered: nil) }
    }
}

/// What a close's read of one live terminal found: its foreground program (nil: its shell only), or no answer in time
/// (the daemon is slow or not connected), which never confirms that no program runs.
public enum ProcessAnswer: Equatable, Sendable {
    case program(String?)
    case noAnswer
}

extension Dictionary where Key == SurfaceID, Value == ProcessAnswer {
    /// The programs of the terminals that answered, unique and sorted.
    public var programNames: [String] {
        Set(values.compactMap { answer -> String? in if case .program(let program) = answer { return program }; return nil }).sorted()
    }
}

/// The one question a close of live terminals can ask (`TabCloseGuard`, #17501): an agent at work in one, else
/// foreground programs, or terminals that gave no answer.
public enum CloseWarning: Equatable, Sendable {
    /// The agent working in a closing terminal (the first, if several).
    case agent(String)
    /// Foreground programs in the closing terminals, unique and sorted, and the titles of the closing terminals that gave
    /// no answer (a tab title is not a program: the question names them apart).
    case programs([String], unanswered: [String] = [])

    /// The question for these closing terminals, or nil to close at once.
    /// `unanswered`: the titles of closing terminals that gave no answer, when no answer asks.
    public static func of(agents: [String], programs: [String], unanswered: [String] = [], warnTab: Bool, warnAgent: Bool) -> CloseWarning? {
        if warnAgent, let agent = agents.first { return .agent(agent) }
        if warnTab, !programs.isEmpty || !unanswered.isEmpty { return .programs(programs, unanswered: unanswered) }
        return nil
    }
}

extension DaemonService {
    /// What each live terminal of `tabs` answered: one bounded read (1 s) per terminal, concurrent. With no connection,
    /// none answers. A stand-in (a terminal still opening) has no process to ask and runs nothing yet: never asked.
    @MainActor public func processAnswers(of tabs: [TabModel]) async -> [SurfaceID: ProcessAnswer] {
        let terminals = tabs.filter { $0.kind == .pty && !$0.dead && !ProvisionalTab.isProvisional(surface: $0.surface) }
        guard let connection, !terminals.isEmpty else {
            var none: [SurfaceID: ProcessAnswer] = [:]
            for tab in terminals { none[tab.surface] = .noAnswer }
            return none
        }
        await closeReadStarts() // a test may hold the read here (debug.close.hold, DEBUG and bench builds)
        return await withTaskGroup(of: (SurfaceID, ProcessAnswer).self) { group in
            for tab in terminals {
                let surface = tab.surface
                group.addTask { (surface, await connection.readProcessInfo(surface, timeout: .seconds(1)).map { ProcessAnswer.program($0.runningProgram) } ?? ProcessAnswer.noAnswer) }
            }
            var answers: [SurfaceID: ProcessAnswer] = [:]
            for await (surface, answer) in group { answers[surface] = answer }
            return answers
        }
    }

    /// Each live terminal of `tabs`' foreground program, or nil when it runs none (``processAnswers(of:)``). One gesture
    /// asks once and passes this on (a close's question, then its undo toast decision).
    /// `unanswered`: what a terminal that gave no answer (or every terminal, with no connection) counts as running;
    /// nil counts it as running none.
    @MainActor public func runningPrograms(of tabs: [TabModel], unanswered: (@MainActor (TabModel) -> String)? = nil) async -> RunningPrograms {
        // No connection: nothing was asked (the base answer, an empty map), unless no answer counts as a program.
        guard connection != nil || unanswered != nil else { return [:] }
        return RunningPrograms(await processAnswers(of: tabs), of: tabs, unanswered: unanswered)
    }
}
