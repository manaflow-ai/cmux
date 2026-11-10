public import CMUXAuthCore
public import CmuxAuthRuntime
import Foundation
public import Observation

/// The signed-in account's team memberships and the selection behind them:
/// `AuthCoordinator` in the app, a fake in tests.
@MainActor
public protocol ActiveTeamSource: AnyObject {
    var isAuthenticated: Bool { get }
    var availableTeams: [CMUXAuthTeam] { get }
    /// The selection API calls target (the persisted one, else the first team).
    var resolvedTeamID: String? { get }
    /// Persists `id` as the account's selected team, then selects it locally.
    func selectTeam(id: String?) async throws
    /// Re-reads membership; a selection the account left falls back to its first team.
    func refreshTeams() async
}

extension AuthCoordinator: ActiveTeamSource {}

/// The team cmux works in: one per signed-in account, the single source of
/// truth for every team-scoped feature (Cloud machines, CodeRouter accounts,
/// phone access, and later Devices). Features read ``id`` or ``team`` and
/// never pick a team themselves; switching goes through ``select(_:)`` from
/// every surface (Settings, the palette's Switch Active Team, the CLI).
///
/// The selection is the account's own (Stack Auth's selected team), cached
/// in `cmux.auth.selectedTeamID`: it follows the account across launches,
/// defaults to the first team, falls back when the account leaves the team,
/// and clears on sign-out. A device restricted to a managed team
/// (``managedTeamID``) sees and uses only that team.
///
/// Stack never lists the person's own platform team, where their own Cloud
/// grant applies (manaflow-ai/cmux#39950), so an unmanaged account also gets a
/// first "Personal" row named by that team's backend id (`team_` and 20 hex
/// digits, ``CloudTeamIDs/personalTeam(project:stackUser:)``; a Stack id never
/// is one). Choosing it is this Mac's, per account (Stack has nothing to
/// save), until a Stack team is chosen again.
@MainActor @Observable
public final class ActiveTeam {
    @ObservationIgnored let source: any ActiveTeamSource
    /// The Stack project and the signed-in Stack user, nil signed out: what the personal team's id derives from.
    @ObservationIgnored private let account: @MainActor () -> (project: String, user: String)?
    /// Where the Personal choice is kept, under `<personalKey>.<stack user>`.
    @ObservationIgnored private let store: any CMUXAuthKeyValueStore
    @ObservationIgnored private let personalKey: String
    /// Bumped on each Personal choice change, so readers of ``id`` and ``teams`` observe the store's flag.
    private var personalRevision = 0
    /// Counts Personal choices, so a Stack save that lands after one never clears it (the newest choice wins).
    @ObservationIgnored private var personalPicks = 0
    /// The backend's confirmed teams for the account (`user.teams.list` ids, set by Home's read), with the user
    /// they belong to: another account's list never filters this one.
    private var confirmed: (user: String, teams: Set<String>)?
    /// `RestrictToManagedTeam` with `ManagedTeam` (enterprise P17-3): the
    /// only team this device may use, or nil. The account's other teams are
    /// neither listed nor selectable, and without that team there is none.
    public var managedTeamID: String?
    /// True while a switch is being saved.
    public private(set) var isSwitching = false

    /// `account` names the signed-in Stack user and project (none: no Personal row, as in tests of the Stack
    /// teams alone); `store` keeps the Personal choice (none: memory only), under `personalKey` and the user.
    public init(source: any ActiveTeamSource, account: @escaping @MainActor () -> (project: String, user: String)? = { nil },
                store: (any CMUXAuthKeyValueStore)? = nil, personalKey: String = "cmux.next.activeTeam.personal") {
        self.source = source
        self.account = account
        self.store = store ?? MemoryAuthKeyValueStore()
        self.personalKey = personalKey
    }

    /// The backend team ids (`team_…`) the backend's `user.teams.list` lists for the signed-in account, from a
    /// complete reply; nil before one is read (or after an incomplete one). When set, ``teams`` drops the Stack
    /// teams it does not list: a Stack team the backend ignores (the legacy VM API's tenant, also named
    /// "Personal") is no team cmux can work in.
    public var confirmedTeams: Set<String>? {
        get { account().flatMap { account in confirmed?.user == account.user ? confirmed?.teams : nil } }
        set { confirmed = newValue.flatMap { teams in account().map { (user: $0.user, teams: teams) } } }
    }

    /// The signed-in, unmanaged account's personal team (Rust's `identity::personal_team_id`), nil otherwise.
    public var personalTeamID: String? {
        guard managedTeamID == nil, source.isAuthenticated, let account = account() else { return nil }
        return CloudTeamIDs.personalTeam(project: account.project, stackUser: account.user)
    }

    /// Whether the account chose its personal team on this Mac.
    private var personalChosen: Bool {
        _ = personalRevision
        guard let user = account()?.user else { return false }
        return store.bool(forKey: "\(personalKey).\(user)")
    }

    private func choosePersonal(_ chosen: Bool) {
        guard let user = account()?.user else { return }
        store.set(chosen, forKey: "\(personalKey).\(user)")
        personalRevision += 1
    }

    /// The account's teams this device may use (Rust's `cloud_auth_team`: only the managed one on a managed device):
    /// unmanaged, the Personal row first, then the Stack teams the backend confirms (``confirmedTeams``).
    public var teams: [CMUXAuthTeam] {
        var available = source.availableTeams
        guard managedTeamID != nil else {
            if let confirmed = confirmedTeams, let project = account()?.project {
                available.removeAll { !confirmed.contains(CloudTeamIDs.teamHeader(project: project, team: $0.id)) }
            }
            guard let personal = personalTeamID else { return available }
            return [CMUXAuthTeam(id: personal, displayName: "Personal")] + available
        }
        let allowed = Set(Self.answer(requesting: nil, resolved: source.resolvedTeamID, available: available.map(\.id),
                                      managed: managedTeamID)?.allowed ?? [])
        return available.filter { allowed.contains($0.id) }
    }

    /// The active team's id, or nil (signed out, no team, or the managed team missing).
    /// It can be set before ``teams`` loads: the cached selection stays in effect meanwhile.
    public var id: String? {
        // Unmanaged, the active team is the Personal choice, else the resolved one (Rust's `allowed_team_id`); the
        // read stays local.
        guard managedTeamID != nil else {
            if personalChosen, let personal = personalTeamID { return personal }
            return source.resolvedTeamID
        }
        return Self.answer(requesting: nil, resolved: source.resolvedTeamID, available: source.availableTeams.map(\.id),
                           managed: managedTeamID)?.active
    }

    /// The active team, once membership has loaded.
    public var team: CMUXAuthTeam? {
        guard let id else { return nil }
        return teams.first { $0.id == id }
    }

    /// Whether the person can switch to another team here.
    public var canSwitch: Bool { managedTeamID == nil && teams.count > 1 && !isSwitching }

    /// Why a switch was refused.
    public enum Refusal: String, Error, Equatable, Sendable {
        case signedOut
        /// The device is restricted to another team.
        case managed
        /// The account is not a member of that team.
        case notMember
        /// A call named a team that is not the active one.
        case notActive
    }

    /// Why a call naming `requested` (nil or blank: the active team) may not act in it:
    /// everything acts in the active team, and a managed device only in its managed team.
    public func refusal(requesting requested: String?) -> Refusal? {
        Self.refusal(requesting: requested, active: id, managed: managedTeamID)
    }

    nonisolated static func refusal(requesting requested: String?, active: String?, managed: String?) -> Refusal? {
        // An FFI that does not answer refuses as managed: a call never acts in a team unchecked.
        guard let answer = answer(requesting: requested, resolved: active, available: active.map { [$0] } ?? [], managed: managed) else {
            return .managed
        }
        return answer.refusal.flatMap(Refusal.init(rawValue:))
    }

    /// Rust's team rules (cmux-cloud-config `auth::allowed_team_id`, `team_refusal`).
    struct Answer: Decodable {
        var active: String?
        var refusal: String?
        var allowed: [String]
    }

    nonisolated static func answer(requesting requested: String?, resolved: String?, available: [String], managed: String?) -> Answer? {
        struct Request: Encodable { var requested: String?, resolved: String?, available: [String], managed: String? }
        return CloudStartCore().call("cloud_auth_team", Request(requested: requested, resolved: resolved, available: available, managed: managed),
                                     as: Answer.self)
    }

    /// Makes `id` the active team: saved for the account first, so a refused
    /// save leaves the current team in effect. Selecting the active team is a no-op.
    /// A choice made while a save is in flight replaces any earlier waiting one, and
    /// the running switch saves it next: the newest choice is the team cmux ends in.
    /// The personal team (``personalTeamID``) is kept on this Mac only, never saved to
    /// Stack; a saved Stack team ends that choice.
    public func select(_ id: String) async throws {
        guard source.isAuthenticated else { throw Refusal.signedOut }
        guard managedTeamID == nil || id == managedTeamID else { throw Refusal.managed }
        if let personal = personalTeamID, id == personal {
            next = nil // a Stack choice still waiting is older than this one
            personalPicks += 1
            choosePersonal(true)
            return
        }
        guard source.availableTeams.contains(where: { $0.id == id }) else { throw Refusal.notMember }
        next = id
        guard !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false; next = nil }
        while let target = next {
            next = nil
            // Checked again: a refresh, a sign-out or a managed-team change can land during a save.
            guard source.isAuthenticated else { throw Refusal.signedOut }
            guard managedTeamID == nil || target == managedTeamID,
                  source.availableTeams.contains(where: { $0.id == target }), target != self.id else { continue }
            let picks = personalPicks
            do {
                try await source.selectTeam(id: target)
                // Saved: a Stack team is the account's choice now, unless Personal was chosen during the save.
                if picks == personalPicks { choosePersonal(false) }
            } catch {
                if next == nil { throw error } // else a newer choice replaces the one that failed
            }
        }
    }

    /// The newest choice not saved yet, while a switch runs.
    @ObservationIgnored private var next: String?

    /// Re-reads the account's teams (one left or joined elsewhere).
    public func refresh() async {
        guard source.isAuthenticated else { return }
        await source.refreshTeams()
    }
}
