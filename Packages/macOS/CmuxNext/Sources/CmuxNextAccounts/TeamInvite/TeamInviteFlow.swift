import Foundation

/// One team invite from start to answer: find the team, ask the person, and
/// only after Allow ask cmux.com to send the email. Every caller that is not
/// the person's own gesture (CLI, MCP, an agent) goes through here, so no
/// invite, which can add a paid seat on accept, leaves without a yes.
@MainActor
public struct TeamInviteFlow {
    private let backend: any TeamInviteBackend
    private let consent: any TeamInviteConsenting

    /// Creates the flow.
    ///
    /// - Parameters:
    ///   - backend: The signed-in cmux.com calls.
    ///   - consent: Who asks the person (the App's panel, a test's script).
    public init(backend: any TeamInviteBackend, consent: any TeamInviteConsenting) {
        self.backend = backend
        self.consent = consent
    }

    /// Runs one invite.
    ///
    /// - Parameters:
    ///   - input: The validated arguments.
    ///   - requester: Who asked, for the confirmation.
    /// - Returns: The receipt, or why nothing was sent.
    public func run(_ input: TeamInviteInput, requester: TeamInviteRequester) async -> Result<TeamInviteReceipt, TeamInviteRefusal> {
        .failure(TeamInviteRefusal(code: "unavailable", message: "not implemented"))
    }
}
