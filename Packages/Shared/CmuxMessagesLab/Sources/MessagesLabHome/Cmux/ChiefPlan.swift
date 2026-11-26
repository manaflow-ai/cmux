import Foundation
import Observation

/// cmux: the Chief's plan (Leo 2026-10-20, "trust and visibility"): one step per subagent the Chief
/// started, with its owner, a live state and its pull requests. The Chief screen's inspector draws
/// it as the Plan section, and the transcript draws an assignment table of a Chief reply as a plan
/// card from the same steps. Values only: the app builds it from the Chief's acpmux lanes and the
/// pull requests its subagents reported, and publishes it on a ``ChiefPlanBoard``.
public struct ChiefPlan: Hashable, Sendable {
    public var steps: [ChiefPlanStep]

    public init(steps: [ChiefPlanStep] = []) {
        self.steps = steps
    }

    public static let empty = ChiefPlan()

    /// The step a subagent owns (`a12`), compared without case.
    public func step(owner: String) -> ChiefPlanStep? {
        let key = owner.lowercased()
        return steps.first { $0.owner?.lowercased() == key }
    }

    /// The step whose pull request `url` names (the same PR number on the same repository).
    public func step(pullRequest url: String) -> ChiefPlanStep? {
        guard let key = ChiefPlanPullRequest.key(url) else { return nil }
        return steps.first { $0.pullRequests.contains { ChiefPlanPullRequest.key($0.url) == key } }
    }

    /// How many steps are in each state, for the section's one-line summary.
    public var counts: [ChiefPlanStep.State: Int] {
        steps.reduce(into: [:]) { $0[$1.state, default: 0] += 1 }
    }

    /// Steps still running or waiting on something: not landed, done or failed.
    public var activeCount: Int { steps.count(where: { $0.state.isActive }) }
}

/// One step of the plan: the work one subagent owns.
public struct ChiefPlanStep: Hashable, Sendable, Identifiable {
    /// What the step is doing now, in the order a person reads them.
    public enum State: String, Hashable, Sendable, CaseIterable, Codable {
        /// A turn runs.
        case working
        /// It waits on the person: a permission or a question.
        case needsInput
        /// Its pull request's checks run.
        case waitingOnCI
        /// Its pull request's checks failed.
        case ciFailed
        /// Its pull request is open and green, waiting for review or the merge queue.
        case inReview
        /// Its pull request merged.
        case landed
        /// It finished without a pull request (a report, an audit).
        case done
        /// Its last turn failed, or its agent is gone.
        case failed

        /// Still running or waiting on something.
        public var isActive: Bool {
            switch self {
            case .working, .needsInput, .waitingOnCI, .inReview: true
            case .ciFailed, .landed, .done, .failed: false
            }
        }

        /// A person should look.
        public var needsAttention: Bool { self == .needsInput || self == .ciFailed || self == .failed }
    }

    /// What the agent itself is doing, as acpmux reports it.
    public enum AgentState: String, Hashable, Sendable {
        case working, input, idle, failed, lost
    }

    /// The subagent id (`a12`), else its session id.
    public var id: String
    public var title: String
    /// The subagent id the owner chip shows (`a12`); nil when the session has none.
    public var owner: String?
    /// Where the owner chip goes: the subagent's chat or workspace (a `cmux://` app link).
    public var ownerLink: URL?
    public var state: State
    /// What it is doing now, one line (acpmux's masked step), or its error.
    public var detail: String?
    /// Since when it has been in its agent state.
    public var since: Date?
    public var pullRequests: [ChiefPlanPullRequest]

    public init(id: String, title: String, owner: String? = nil, ownerLink: URL? = nil, state: State, detail: String? = nil,
                since: Date? = nil, pullRequests: [ChiefPlanPullRequest] = []) {
        self.id = id
        self.title = title
        self.owner = owner
        self.ownerLink = ownerLink
        self.state = state
        self.detail = detail
        self.since = since
        self.pullRequests = pullRequests
    }

    /// The step's state from its agent's state and its pull requests. A live agent turn wins
    /// (a subagent fixing CI is working); then its newest pull request decides; an idle agent
    /// without one is done.
    public static func state(agent: AgentState?, pullRequests: [ChiefPlanPullRequest]) -> State {
        switch agent {
        case .working?: return .working
        case .input?: return .needsInput
        case .failed?, .lost?: return pullRequests.isEmpty ? .failed : prState(pullRequests)
        case .idle?, nil: return pullRequests.isEmpty ? .done : prState(pullRequests)
        }
    }

    /// The state the pull requests give: every one merged is landed; else the first open one's checks.
    private static func prState(_ prs: [ChiefPlanPullRequest]) -> State {
        if prs.allSatisfy({ $0.state == .merged || $0.state == .closed }) {
            return prs.contains { $0.state == .merged } ? .landed : .done
        }
        let open = prs.filter { $0.state == .open || $0.state == .draft }
        if open.contains(where: { $0.checks == .failing }) { return .ciFailed }
        if open.contains(where: { $0.checks == .pending }) { return .waitingOnCI }
        return .inReview
    }
}

/// A pull request a step owns, as far as the plan needs it.
public struct ChiefPlanPullRequest: Hashable, Sendable, Identifiable {
    public enum State: String, Hashable, Sendable { case open, draft, merged, closed, unknown }
    public enum Checks: String, Hashable, Sendable { case passing, failing, pending, none, unknown }

    /// Always https.
    public var url: String
    public var number: Int
    public var title: String
    public var state: State
    public var checks: Checks
    /// Passed and total checks; zero when unknown.
    public var passed: Int
    public var total: Int

    public var id: String { url }

    public init(url: String, number: Int, title: String = "", state: State = .unknown, checks: Checks = .unknown,
                passed: Int = 0, total: Int = 0) {
        self.url = url
        self.number = number
        self.title = title
        self.state = state
        self.checks = checks
        self.passed = passed
        self.total = total
    }

    /// A GitHub pull request link: `https://github.com/OWNER/REPO/pull/N` (any trailing path), else nil.
    public init?(link: String) {
        guard let key = Self.key(link) else { return nil }
        let parts = key.split(separator: "#")
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        self.init(url: "https://github.com/\(parts[0])/pull/\(number)", number: number)
    }

    /// `owner/repo#N` for a GitHub pull request link, lowercased; nil for anything else.
    public static func key(_ link: String) -> String? {
        guard let url = URL(string: link), url.scheme == "https", url.host?.lowercased() == "github.com" else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count >= 4, path[2] == "pull", let number = Int(path[3]), number > 0 else { return nil }
        return "\(path[0].lowercased())/\(path[1].lowercased())#\(number)"
    }
}

/// The live plan the host publishes for the views that draw it (the inspector and the transcript's
/// plan cards). Observable: a view reads ``plan`` inside an observation and redraws when it changes.
@Observable @MainActor
public final class ChiefPlanBoard {
    public var plan: ChiefPlan = .empty

    public init() {}
}
