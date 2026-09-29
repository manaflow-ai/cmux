public import CmuxNextSettings

/// A validated `action.run` request: the canonical action ID, the target,
/// and arguments already checked against the action's schema.
public struct ControlActionRequest: Sendable, Hashable {
    public var actionID: String
    public var target: ControlTargetRef?
    public var arguments: [String: ControlValue]

    public init(actionID: String, target: ControlTargetRef? = nil, arguments: [String: ControlValue] = [:]) {
        self.actionID = actionID
        self.target = target
        self.arguments = arguments
    }
}

/// What happened when the executor tried to run an action.
public enum ControlActionOutcome: Sendable, Hashable {
    case ran
    case unknownAction
    /// The catalog has the action but the App bound no handler.
    case notBound
    /// Its required context is missing (for example a browser action with
    /// no browser focused).
    case unavailable
    /// Its handler's `isEnabled` predicate refused.
    case disabled
    /// Bound as unavailable in this build, with a user-facing reason.
    case unsupported(reason: String)
    /// The handler ran and reported why it did nothing.
    case failed(reason: String)
}
