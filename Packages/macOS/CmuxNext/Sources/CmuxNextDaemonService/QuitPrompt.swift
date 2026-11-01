/// The quit alert's content.
public struct QuitPrompt: Equatable, Sendable {
    public var terminals: Int
    public var runningPrograms: Int
    /// The busiest program names (most CPU first), at most `QuitRules.busiestLimit`.
    public var busiest: [String]
    public var incognitoPrograms: [String]
    public var remoteSessions: Bool
    /// False when only incognito terminals are at stake, or a remembered
    /// end applies: the alert then only confirms the incognito close (Quit
    /// and Cancel).
    public var offersSessionChoice: Bool
    /// The button Return presses.
    public var defaultChoice: QuitSessionsChoice
    /// A remembered End Everything asks before it deletes the workspaces:
    /// Keep Sessions Running (Return), Cancel (Escape), End Everything (no
    /// key). A Cmd-Q typed by mistake never closes every workspace
    /// (2026-10-31: 900 closed with no dialog).
    public var confirmsEndEverything: Bool
    /// Live local agents that keep running; nil when acpmux did not answer.
    public var agents: Int?
    /// Local agents in a turn now.
    public var agentsInTurn: Int
    /// Their titles, at most `QuitRules.busiestLimit`.
    public var busyAgents: [String]
    /// The Home Chief is in a turn: one line "Chief keeps running".
    public var chiefKeepsRunning: Bool

    public init(terminals: Int, runningPrograms: Int, busiest: [String], incognitoPrograms: [String], remoteSessions: Bool,
                offersSessionChoice: Bool, defaultChoice: QuitSessionsChoice, confirmsEndEverything: Bool = false,
                agents: Int? = 0, agentsInTurn: Int = 0, busyAgents: [String] = [], chiefKeepsRunning: Bool = false) {
        self.terminals = terminals
        self.runningPrograms = runningPrograms
        self.busiest = busiest
        self.incognitoPrograms = incognitoPrograms
        self.remoteSessions = remoteSessions
        self.offersSessionChoice = offersSessionChoice
        self.defaultChoice = defaultChoice
        self.confirmsEndEverything = confirmsEndEverything
        self.agents = agents
        self.agentsInTurn = agentsInTurn
        self.busyAgents = busyAgents
        self.chiefKeepsRunning = chiefKeepsRunning
    }
}
