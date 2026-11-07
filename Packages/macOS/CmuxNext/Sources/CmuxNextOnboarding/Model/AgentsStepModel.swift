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
    /// Its CLI is on this Mac. A missing one is listed only when cmux can install it
    /// (``installPage`` is set), with an Install instead of a Sign In.
    public let installed: Bool

    public init(id: String, name: String, brand: String?, auth: Auth, installed: Bool = true) {
        self.id = id
        self.name = name
        self.brand = brand
        self.auth = auth
        self.installed = installed
    }

    /// Sign In shows for every installed agent not known to be signed in (Claude Code reports unknown).
    public var offersSignIn: Bool { installed && auth != .signedIn }

    /// The vendor's own install page for an agent cmux can install (`acpmux harness install`),
    /// shown beside Install for a person who would rather install it by hand; nil for any other.
    public var installPage: URL? { Self.installPages[id] }

    public static let installPages: [String: URL] = [
        "claude": "https://docs.anthropic.com/en/docs/claude-code/setup",
        "codex": "https://developers.openai.com/codex/cli",
    ].compactMapValues(URL.init(string:))
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
    /// Installs `id`'s CLI through its vendor's official installer (`acpmux harness install`),
    /// only because the person pressed Install. Nil when it installed, else what went wrong.
    func installAgent(_ id: String) async -> String?
    /// The agent's mark at `side` points, nil for the generic glyph.
    func agentIcon(_ agent: OnboardingAgent, side: CGFloat) -> NSImage?
}

/// The first-run Agents step: each installed agent CLI with its sign-in and a Sign In that
/// types the agent's login into a terminal tab, and each missing one cmux can install with an
/// Install that runs the vendor's installer and then signs in. Nothing installs unless pressed
/// (Leo, 2026-11-06: offer, never auto-install). Continue and Skip both leave, signed in or not.
@MainActor
@Observable
public final class AgentsStepModel {
    /// An Install the person pressed: running, or what went wrong (shown beside its button).
    public enum Install: Sendable, Equatable {
        case installing
        case failed(String)
    }

    /// The installed agents, each with its sign-in.
    public private(set) var agents: [OnboardingAgent] = []
    /// The agents cmux can install that are not on this Mac (Claude Code, Codex).
    public private(set) var installable: [OnboardingAgent] = []
    /// Each pressed Install by agent id; an agent with none shows its Install at rest.
    public private(set) var installs: [String: Install] = [:]
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
            show(fresh)
            // Signed in now: the line under the list and the rechecks on coming back stop.
            if fresh.contains(where: { $0.id == signingIn && $0.auth == .signedIn }) { signingIn = nil }
            loading = false
            loaded = true
            read = nil
        }
    }

    private func show(_ fresh: [OnboardingAgent]) {
        agents = fresh.filter(\.installed)
        installable = fresh.filter { !$0.installed && $0.installPage != nil }
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

    /// Install: the agent's vendor installer, then its row reads again and its Sign In runs,
    /// so the person goes straight from Install to the login. A failure stays beside the button.
    public func install(_ id: String) {
        // One install at a time: a second could finish first and its read would skip this one's sign-in.
        guard installable.contains(where: { $0.id == id }), !installs.values.contains(.installing) else { return }
        installs[id] = .installing
        // task-owner: one install the person asked for; it ends with the installer (acpmux bounds it).
        Task { [weak self, source] in
            let failure: String? = if let source { await source.installAgent(id) } else { "cmux could not reach its agents service" }
            guard let self else { return }
            if let failure {
                installs[id] = .failed(failure)
                return
            }
            // The read after the install wins over any read in flight from before it.
            read?.cancel()
            read = nil
            generation += 1
            let mine = generation
            let fresh = await source?.agentSignIns(recheck: true) ?? []
            guard mine == generation else { return installs[id] = nil }
            show(fresh)
            loading = false
            loaded = true
            // The installer finished but acpmux does not find the agent yet: say so beside the button.
            guard agents.contains(where: { $0.id == id }) else {
                return installs[id] = .failed("installed, but cmux does not find it yet; reopen cmux to look again")
            }
            installs[id] = nil
            signIn(id)
        }
    }

    func stop() {
        read?.cancel()
        read = nil
        loading = false
    }
}
