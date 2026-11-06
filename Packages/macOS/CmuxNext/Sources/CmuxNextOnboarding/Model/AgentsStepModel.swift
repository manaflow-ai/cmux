public import AppKit
public import Observation

/// One agent CLI on this Mac and whether it is signed in, as acpmux reports it.
public struct OnboardingAgent: Sendable, Equatable {
    public enum Auth: String, Sendable {
        case signedIn, signedOut, expired, unknown
    }

    public let id: String
    public let name: String
    /// The agent's mark id (the App draws it); nil for the generic glyph.
    public let brand: String?
    public let auth: Auth

    public init(id: String, name: String, brand: String?, auth: Auth) {
        self.id = id
        self.name = name
        self.brand = brand
        self.auth = auth
    }

    /// Sign In shows for every agent not known to be signed in (Claude Code reports unknown).
    public var offersSignIn: Bool { auth != .signedIn }
}

/// The installed agent CLIs and their sign-ins (the App's acpmux harnesses): what the Agents
/// step lists and what its Sign In runs. No credential is read through it; acpmux reports the state.
@MainActor
public protocol AgentSignInSource: AnyObject {
    /// The agent CLIs installed on this Mac with their sign-in (`recheck`: acpmux checks
    /// again). Empty when acpmux is not here or did not answer.
    func agentSignIns(recheck: Bool) async -> [OnboardingAgent]
    /// Types `id`'s login into a new terminal tab; false when no tab could open.
    func signInAgent(_ id: String) async -> Bool
    /// The agent's mark at `side` points, nil for the generic glyph.
    func agentIcon(_ agent: OnboardingAgent, side: CGFloat) -> NSImage?
}

/// The first-run Agents step: each installed agent CLI with its sign-in and a Sign In that
/// types the agent's login into a terminal tab. Nothing to type here; Continue and Skip both
/// leave, signed in or not.
@MainActor
@Observable
public final class AgentsStepModel {
    public private(set) var agents: [OnboardingAgent] = []
    /// A read is in flight; the list keeps what it showed.
    public private(set) var loading = false
    /// The first read answered (an empty list then says no agents were found).
    public private(set) var loaded = false
    /// The agent whose Sign In ran last; its terminal tab is where the login runs.
    public private(set) var signingIn: String?
    /// Sign In could not open its terminal tab.
    public private(set) var signInFailed = false
    @ObservationIgnored let source: (any AgentSignInSource)?
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(source: (any AgentSignInSource)?) {
        self.source = source
    }

    /// Reads the agents when the step shows.
    func start() {
        guard !loaded, read == nil else { return }
        refresh(recheck: false)
    }

    /// Reads the agents again (`recheck`: acpmux checks each sign-in again). The newest read wins.
    public func refresh(recheck: Bool) {
        read?.cancel()
        generation += 1
        let mine = generation
        loading = true
        // task-owner: one acpmux read for the shown step; a newer read or stop() cancels it.
        read = Task { [weak self, source] in
            let fresh = await source?.agentSignIns(recheck: recheck) ?? []
            guard let self, !Task.isCancelled, mine == generation else { return }
            agents = fresh
            // Signed in now: the line under the list and the rechecks on coming back stop.
            if fresh.contains(where: { $0.id == signingIn && $0.auth == .signedIn }) { signingIn = nil }
            loading = false
            loaded = true
            read = nil
        }
    }

    /// The window became key again: after a Sign In, acpmux checks the sign-ins again.
    public func cameBack() {
        guard signingIn != nil else { return }
        refresh(recheck: true)
    }

    /// Sign In: the agent's login in a terminal tab, where the person answers it.
    public func signIn(_ id: String) {
        guard let agent = agents.first(where: { $0.id == id }), agent.offersSignIn else { return }
        signingIn = id
        signInFailed = false
        // task-owner: one sign-in the person asked for; it only opens the terminal tab.
        Task { [weak self, source] in
            let opened = await source?.signInAgent(id) ?? false
            guard let self, signingIn == id else { return }
            signInFailed = !opened
        }
    }

    func stop() {
        read?.cancel()
        read = nil
        loading = false
    }
}
