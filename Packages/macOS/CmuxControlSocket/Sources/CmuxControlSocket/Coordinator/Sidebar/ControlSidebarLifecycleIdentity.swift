public import Foundation

/// Identity facts attached to a live agent lifecycle event.
///
/// The app uses these values to reject delayed hook events before they can
/// consume the current pane's bounded PTY capture. Legacy callers may leave
/// the fields unset; managed prompt-boundary events are admitted only when
/// their required identity is present.
public struct ControlSidebarLifecycleIdentity: Sendable, Equatable {
    /// The terminal process generation that emitted the event.
    public let terminalLifecycleID: UUID?
    /// The managed agent session or checkpoint identifier.
    public let sessionID: String?
    /// The provider turn identifier, when supplied by the hook.
    public let turnID: String?

    /// Creates an identity snapshot.
    public init(
        terminalLifecycleID: UUID? = nil,
        sessionID: String? = nil,
        turnID: String? = nil
    ) {
        self.terminalLifecycleID = terminalLifecycleID
        let normalizedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTurnID = turnID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = normalizedSessionID?.isEmpty == false ? normalizedSessionID : nil
        self.turnID = normalizedTurnID?.isEmpty == false ? normalizedTurnID : nil
    }

    /// Whether the producer supplied no identity facts.
    public var isEmpty: Bool {
        terminalLifecycleID == nil && sessionID == nil && turnID == nil
    }
}
