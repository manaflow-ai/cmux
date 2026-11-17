public import CmuxNextCloud
public import CmuxNextDaemon
import Foundation

/// Cloud plans and machine sizes on the page (a new chat's Cloud start): the size a start's machine needs for its folder
/// or repository, the plan the page reads before Send (`cloudMachine.list`'s `plan`), the start's plan and size refusals
/// (`cloud_plan_required`, `cloud_size_locked`) and the pricing card's Subscribe (`cloud.plan.subscribe`).
extension AgentPaneCloudStart {
    /// This start with the size its folder `local` needs (``CloudMoveCLI/StartChatPreflight``) and the bytes its copy
    /// sends; throws the preflight's refusal, and `cloud_folder_too_big` for a folder past the largest chat size.
    public func sized(_ preflight: CloudMoveCLI.StartChatPreflight, local: String) throws -> Self {
        var sized = self
        sized.size = try preflight.size(folder: CloudMoveCLI.shownFolder(local))
        if case .passed(let bytes, _) = preflight { sized.folderBytes = bytes }
        return sized
    }

    /// This start with the size its GitHub repository needs, from the size the repos list gave it (`size_kb`,
    /// `sizes`, the App's ``AgentPaneGitHub/sizes``); `sm` when the list named none (or there is no list). A repository
    /// past the largest chat size is `cloud_folder_too_big`. A start that names no repository is unchanged.
    @MainActor public func sizedForRepository(_ sizes: AgentPaneGitHubRepoSizes?) throws -> Self {
        guard let repository else { return self }
        let sizeKb = sizes?.sizeKb(of: repository)
        var sized = self
        sized.folderBytes = sizeKb.flatMap { kb in
            let bytes = Int64(max(kb, 0)).multipliedReportingOverflow(by: 1024)
            return bytes.overflow ? nil : bytes.partialValue
        }
        guard let size = CloudChatSize.forRepository(sizeKb: sizeKb) else {
            throw CloudMoveCLI.StartChatPreflightRefusal(message: "\(repository) is too big for a Cloud machine", folder: repository,
                                                         bytes: sized.folderBytes.map(Double.init))
        }
        sized.size = size
        return sized
    }
}

/// The sizes the GitHub repos list gave (`github.repos.list`'s rows, `size_kb`), by `owner/name`: a start in a picked
/// repository reads its size here. Bounded: a list past ``limit`` names starts over. The App's ``AgentPaneGitHub`` owns
/// one (``AgentPaneGitHub/sizes``), shared by every pane's copy; a test makes its own.
@MainActor public final class AgentPaneGitHubRepoSizes {
    static let limit = 5_000
    private var sizes: [String: Int] = [:]

    public init() {}

    func note(_ repos: [CloudGitHubRepos.Repo]) {
        if sizes.count + repos.count > Self.limit { sizes.removeAll() }
        for repo in repos { sizes[repo.fullName.lowercased()] = repo.sizeKb }
    }

    /// The size the list gave `repository` (`owner/name`), in GitHub's KB; nil when it gave none.
    public func sizeKb(of repository: String) -> Int? { sizes[repository.lowercased()] }
}

extension AgentPaneCloudMachines {
    /// The Cloud plan before Send (`cloudMachine.list`'s `plan`): `active` with its id and the largest size it allows,
    /// `none` only when the server answered that the team has no plan, else `unknown` (not read, signed out, failed),
    /// which never gates: company and stub teams are decided by the server, never by plan names here.
    public struct Plan: Equatable, Sendable {
        public enum State: String, Sendable { case active, noPlan = "none", unknown }
        public var state: State
        public var id: String?
        public var maxSize: CloudChatSize?

        public static let unknown = Plan(state: .unknown)

        public init(state: State, id: String? = nil, maxSize: CloudChatSize? = nil) {
            (self.state, self.id, self.maxSize) = (state, id, maxSize)
        }

        /// From `cloud.plan.get`'s reply: `plan_state` (`active`, `none`, `unknown`), `plan_id` and `max_size` (`sm` to
        /// `2xl`, null). An older server sends no `plan_state`: `unknown`, which never gates.
        public init(planGet reply: JSONValue?) {
            guard let state = reply?["plan_state"]?.stringValue.flatMap(State.init(rawValue:)) else {
                self = .unknown
                return
            }
            let id = reply?["plan_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            self.init(state: state, id: state == .unknown ? nil : id,
                      maxSize: state == .active ? reply?["max_size"]?.stringValue.flatMap(CloudChatSize.init(rawValue:)) : nil)
        }

        var reply: [String: Any] {
            ["state": state.rawValue, "id": id.map { $0 as Any } ?? NSNull(), "max_size": maxSize.map { $0.rawValue as Any } ?? NSNull()]
        }
    }
}

/// The last plan read, for one account at a time: kept by the App-wide ``AgentPaneCloudMachines``.
@MainActor public final class AgentPaneCloudPlanReads {
    private var kept: (account: [String?], plan: AgentPaneCloudMachines.Plan, at: ContinuousClock.Instant)?

    public init() {}

    /// The plan of `account` (its user and team), from `get` (`cloud.plan.get`) at most once per `age`: an
    /// open picker reads the list every few seconds. A failed read is `unknown` and is not kept.
    public func read(account: [String?]?, age: Duration = .seconds(60), now: ContinuousClock.Instant = .now,
                     _ get: () async throws -> JSONValue) async -> AgentPaneCloudMachines.Plan {
        guard let account else { return .unknown }
        if let kept, kept.account == account, now - kept.at < age { return kept.plan }
        guard let reply = try? await get() else { return .unknown }
        let plan = AgentPaneCloudMachines.Plan(planGet: reply)
        kept = (account, plan, now)
        return plan
    }
}

/// The start card's plan refusal (webviews CloudStartView.tsx).
extension AgentPaneCloudMachines.Plan {
    /// The plans the pricing card offers.
    public nonisolated static let offered = ["pro", "max"]

    /// `cloud_plan_required`'s details: the teams (``CloudAuth/planRefusalTeams``) and the plans to subscribe to.
    public nonisolated static func requiredDetails(_ teams: [String: Any]) -> [String: Any] {
        teams.merging(["plans": offered]) { _, plans in plans }
    }
}

extension CloudSizeLocked {
    /// The start card's `cloud_size_locked`: the size the folder needs, the largest the plan allows (`planMax`, the
    /// plan's own when known), the plan that lifts it and the folder's bytes; Retry once the plan changed.
    public nonisolated func reply(planMax: CloudChatSize?) -> [String: Any] {
        let details: [String: Any] = [
            "needed": needed.map { $0.rawValue as Any } ?? NSNull(),
            "allowed": allowed(planMax: planMax).map { $0.rawValue as Any } ?? NSNull(),
            "upgrade_plan": upgrade.map { $0 as Any } ?? NSNull(),
            "folder_bytes": folderBytes.map { $0 as Any } ?? NSNull(),
        ]
        return AgentPaneReply.failure(code: Self.pageCode, message: Self.pageCode, details: details, retryable: true, origin: "native")
    }
}
