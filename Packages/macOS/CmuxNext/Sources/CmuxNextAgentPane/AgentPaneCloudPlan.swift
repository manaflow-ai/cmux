public import CmuxNextCloud
public import CmuxNextDaemon
import Foundation

/// Cloud plans and machine sizes on the page (a new chat's Cloud start): the size a start's machine needs for its folder
/// or repository, the plan the page reads before Send (`cloudMachine.list`'s `plan`), the start's plan and size refusals
/// (`cloud_plan_required`, `cloud_size_locked`) and the pricing card's Subscribe (`cloud.plan.subscribe`).
extension AgentPaneCloudStart {
    /// This start with the size its folder `local` needs (``CloudMoveCLI/StartChatPreflight``) under the page's plan
    /// (``planMax``, ``CloudChatSize/planned(bytes:planMax:)``) and the bytes its copy sends; throws the preflight's
    /// refusal, and `cloud_folder_too_big` for a folder too big for a Cloud machine.
    public func sized(_ preflight: CloudMoveCLI.StartChatPreflight, local: String) throws -> Self {
        var sized = self
        var preflight = preflight
        if case .passed(let bytes?, _) = preflight {
            preflight = .passed(bytes: bytes, size: CloudChatSize.planned(bytes: bytes, planMax: planMax))
        }
        sized.size = try preflight.size(folder: CloudMoveCLI.shownFolder(local))
        if case .passed(let bytes, _) = preflight { sized.folderBytes = bytes }
        return sized
    }

    /// This start with the size its GitHub repository needs, from the size the repos list gave it (`size_kb`,
    /// `sizes`, the App's ``AgentPaneGitHub/sizes``) under the page's plan (``planMax``, as ``sized(_:local:)``); `sm` when
    /// the list named none (or there is no list). A repository too big for a Cloud machine is `cloud_folder_too_big`. A
    /// start that names no repository is unchanged.
    @MainActor public func sizedForRepository(_ sizes: AgentPaneGitHubRepoSizes?) throws -> Self {
        guard let repository else { return self }
        let sizeKb = sizes?.sizeKb(of: repository)
        var sized = self
        sized.folderBytes = sizeKb.flatMap { kb in
            let bytes = Int64(max(kb, 0)).multipliedReportingOverflow(by: 1024)
            return bytes.overflow ? nil : bytes.partialValue
        }
        let natural = CloudChatSize.forRepository(sizeKb: sizeKb)
        guard let size = sized.folderBytes.map({ CloudChatSize.planned(bytes: $0, planMax: planMax) }) ?? natural else {
            throw CloudMoveCLI.StartChatPreflightRefusal(message: "\(repository) is too big for a Cloud machine", folder: repository,
                                                         bytes: sized.folderBytes.map(Double.init))
        }
        sized.size = size
        return sized
    }

    /// The disk in MiB its machine's create asks beyond ``size``'s own (``CloudChatSize/grownDiskMb(_:bytes:planMax:)``,
    /// the same disk cmux-tui's ensure sends as `disk_gib`); nil: the size's own.
    public var grownDiskMb: Int? { CloudChatSize.grownDiskMb(size, bytes: folderBytes, planMax: planMax) }
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

/// The last `active` plan read, for one account at a time: kept by the App-wide ``AgentPaneCloudMachines``. A `none`
/// or `unknown` (the answers that gate or could) is never kept: the next read asks the server again, so a plan bought
/// a moment ago is seen at once.
@MainActor public final class AgentPaneCloudPlanReads {
    private var kept: (account: [String?], plan: AgentPaneCloudMachines.Plan, at: ContinuousClock.Instant)?
    /// Counts ``forget()``: a read that began before one never keeps its answer after it.
    private var forgets = 0

    public init() {}

    /// The plan of `account` (its user and team), from `get` (`cloud.plan.get`); an `active` answer is reused for
    /// `age` (an open picker reads the list every few seconds). A failed read is `unknown`.
    public func read(account: [String?]?, age: Duration = .seconds(60), now: ContinuousClock.Instant = .now,
                     _ get: () async throws -> JSONValue) async -> AgentPaneCloudMachines.Plan {
        guard let account else { return .unknown }
        if let kept, kept.account == account, now - kept.at < age { return kept.plan }
        let began = forgets
        guard let reply = try? await get() else { return .unknown }
        let plan = AgentPaneCloudMachines.Plan(planGet: reply)
        guard began == forgets else { return plan } // asked before a forget: answered, never kept
        if plan.state == .active { kept = (account, plan, now) } else { kept = nil }
        return plan
    }

    /// The kept `active` plan of `account`, with no read: nil when none is kept (not read yet, `none`, `unknown`, forgotten).
    public func kept(account: [String?]?) -> AgentPaneCloudMachines.Plan? {
        guard let account, let kept, kept.account == account else { return nil }
        return kept.plan
    }

    /// Drops the kept read: the next ``read(account:age:now:_:)`` asks the server (a Subscribe, which may change the
    /// plan, or a page that needs the plan as it is now: `cloudMachine.list {fresh: true}`).
    public func forget() {
        kept = nil
        forgets &+= 1
    }
}

/// The start card's plan refusal (webviews CloudStartView.tsx).
extension AgentPaneCloudMachines.Plan {
    /// The plans the pricing card offers a team with no plan: cmux NEXT's own, smallest first.
    public nonisolated static let offered = ["next_plus", "next_pro", "next_max"]
    /// The plans the cards may name and Subscribe opens: ``offered``, and the classic ones a server may still name
    /// (``CloudSizeLocked/plans``).
    public nonisolated static let subscribable = CloudSizeLocked.plans

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
