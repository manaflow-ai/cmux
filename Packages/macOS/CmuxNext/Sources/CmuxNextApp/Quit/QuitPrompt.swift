/// The quit alert's content.
struct QuitPrompt: Equatable, Sendable {
    var terminals: Int
    var runningPrograms: Int
    /// The busiest program names (most CPU first), at most `QuitPolicy.busiestLimit`.
    var busiest: [String]
    var incognitoPrograms: [String]
    var remoteSessions: Bool
    /// False when only incognito terminals are at stake, or a remembered
    /// end applies: the alert then only confirms the incognito close (Quit
    /// and Cancel).
    var offersSessionChoice: Bool
    /// The button Return presses.
    var defaultChoice: QuitSessionsChoice
    /// Live local agents that keep running; nil when acpmux did not answer.
    var agents: Int? = 0
    /// Local agents in a turn now.
    var agentsInTurn: Int = 0
    /// Their titles, at most `QuitPolicy.busiestLimit`.
    var busyAgents: [String] = []
    /// The Home Chief is in a turn: one line "Chief keeps running".
    var chiefKeepsRunning: Bool = false
}

enum QuitDecision: Equatable, Sendable {
    case quit(QuitSessionsChoice)
    case ask(QuitPrompt)
}
