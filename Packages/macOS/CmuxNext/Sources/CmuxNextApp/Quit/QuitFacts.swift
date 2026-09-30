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
