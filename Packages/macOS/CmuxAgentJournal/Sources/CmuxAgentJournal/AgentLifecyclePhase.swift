/// The lifecycle phase the reducer derives for one agent on one surface.
///
/// This is the journal-side superset of the app's sidebar lifecycle enum: the
/// sidebar has no dedicated error rendering yet, so consumers project
/// ``error`` onto their needs-input treatment while the journal keeps the
/// honest phase.
public enum AgentLifecyclePhase: String, Codable, Sendable, CaseIterable, Equatable {
    /// The agent session exists but has given no activity signal yet.
    case unknown
    /// The agent is actively working on a turn.
    case running
    /// The agent is blocked on the user (approval, question, or plan review).
    case needsInput
    /// The last turn completed and nothing is pending.
    case idle
    /// The agent reported an error and is not making progress.
    case error

    /// Precedence used when several sessions of the same agent share one
    /// surface: the surface shows the most demanding live session.
    ///
    /// Order (most to least demanding): `running` > `needsInput` > `error` >
    /// `unknown` > `idle`.
    public var combinePrecedence: Int {
        switch self {
        case .running: 5
        case .needsInput: 4
        case .error: 3
        case .unknown: 2
        case .idle: 1
        }
    }
}
