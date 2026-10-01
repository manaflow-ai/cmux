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
}

enum QuitDecision: Equatable, Sendable {
    case quit(QuitSessionsChoice)
    case ask(QuitPrompt)
}
