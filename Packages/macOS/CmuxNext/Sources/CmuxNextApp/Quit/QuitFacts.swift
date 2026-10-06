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
    /// The local acpmux daemon's agents (they outlive the app too). Nil when
    /// acpmux has a socket but did not answer in time: unknown, not zero.
    var agents: QuitAgentFacts? = .zero

    static let none = QuitFacts(terminals: 0, programs: [], incognitoPrograms: [], remoteSessions: false)
}

/// The local acpmux daemon's agent sessions, read for an interactive quit.
struct QuitAgentFacts: Equatable, Sendable {
    /// Sessions with a running agent process (ready, running or waiting).
    var live: Int
    /// Sessions in a turn (running, or waiting for a permission answer).
    var inTurn: Int
    /// Titles (else names) of the sessions in a turn, at most `QuitPolicy.busiestLimit`.
    var inTurnNames: [String]
    /// The Home Chief is in a turn. The Chief is never counted above and
    /// never ended by a quit; the dialog says it keeps running.
    var chiefInTurn: Bool = false

    static let zero = QuitAgentFacts(live: 0, inTurn: 0, inTurnNames: [])
}
