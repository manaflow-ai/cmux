/// Runs team invites one at a time for the app's `team.invite` action: a run
/// that arrives while another waits for the person is refused, never queued.
@MainActor
public final class TeamInviteRunner {
    private let consent: any TeamInviteConsenting
    private var running = false

    /// Creates the runner.
    ///
    /// - Parameter consent: The confirmation every run waits on (``TeamInviteConsentPanel`` in the App).
    public init(consent: any TeamInviteConsenting) {
        self.consent = consent
    }

    /// Starts one invite: validated now, then the confirmation and cmux.com in the returned work.
    ///
    /// - Parameters:
    ///   - input: The validated arguments.
    ///   - reasonRequired: Whether the caller is an agent, which must give a reason.
    ///   - requester: Who asked.
    ///   - backend: The signed-in cmux.com calls, nil when nobody is signed in.
    /// - Returns: The work to await, or why the run was refused at once.
    public func start(_ input: TeamInviteInput, reasonRequired: Bool, requester: TeamInviteRequester,
                      backend: (any TeamInviteBackend)?) -> Result<@MainActor () async -> Result<TeamInviteReceipt, TeamInviteRefusal>, TeamInviteRefusal> {
        if reasonRequired, input.reason.isEmpty { return .failure(.reasonRequired) }
        guard let backend else { return .failure(.notSignedIn) }
        guard !running else { return .failure(TeamInviteRefusal(code: "busy", message: TeamInviteStrings.busy)) }
        running = true
        let flow = TeamInviteFlow(backend: backend, consent: consent)
        return .success { [weak self] in
            let result = await flow.run(input, requester: requester)
            self?.running = false
            return result
        }
    }
}
