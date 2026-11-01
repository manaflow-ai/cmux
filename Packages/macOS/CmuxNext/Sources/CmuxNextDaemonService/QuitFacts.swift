/// The local state the quit decision reads.
public struct QuitFacts: Equatable, Sendable {
    /// Local terminals outside incognito windows (they outlive the app).
    public var terminals: Int
    /// Those terminals' foreground programs other than the shell.
    public var programs: [QuitProgram]
    /// Programs running in incognito windows' terminals, which always end.
    public var incognitoPrograms: [String]
    /// Any Cloud or SSH session is known (never ended from the sheet).
    public var remoteSessions: Bool
    /// The local acpmux daemon's agents (they outlive the app too). Nil when
    /// acpmux has a socket but did not answer in time: unknown, not zero.
    public var agents: QuitAgentFacts?

    public init(terminals: Int, programs: [QuitProgram], incognitoPrograms: [String], remoteSessions: Bool,
                agents: QuitAgentFacts? = .zero) {
        self.terminals = terminals
        self.programs = programs
        self.incognitoPrograms = incognitoPrograms
        self.remoteSessions = remoteSessions
        self.agents = agents
    }

    public static let none = QuitFacts(terminals: 0, programs: [], incognitoPrograms: [], remoteSessions: false)
}
