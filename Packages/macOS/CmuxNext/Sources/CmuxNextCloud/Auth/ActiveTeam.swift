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
@MainActor @Observable
public final class ActiveTeam {
    @ObservationIgnored let source: any ActiveTeamSource
    /// `RestrictToManagedTeam` with `ManagedTeam` (enterprise P17-3): the
    /// only team this device may use, or nil. The account's other teams are
    /// neither listed nor selectable, and without that team there is none.
    public var managedTeamID: String?
    /// True while a switch is being saved.
    public private(set) var isSwitching = false

    public init(source: any ActiveTeamSource) {
        self.source = source
    }

    /// The account's teams this device may use (Rust's `cloud_auth_team`: only the managed one on a managed device).
    public var teams: [CMUXAuthTeam] {
        let available = source.availableTeams
        guard managedTeamID != nil else { return available }
        let allowed = Set(Self.answer(requesting: nil, resolved: source.resolvedTeamID, available: available.map(\.id),
                                      managed: managedTeamID)?.allowed ?? [])
        return available.filter { allowed.contains($0.id) }
    }

    /// The active team's id, or nil (signed out, no team, or the managed team missing).
    /// It can be set before ``teams`` loads: the cached selection stays in effect meanwhile.
    public var id: String? {
        // Unmanaged, the active team is the resolved one (Rust's `allowed_team_id`); the read stays local.
        guard managedTeamID != nil else { return source.resolvedTeamID }
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
    public func select(_ id: String) async throws {
        guard source.isAuthenticated else { throw Refusal.signedOut }
        guard managedTeamID == nil || id == managedTeamID else { throw Refusal.managed }
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
            do {
                try await source.selectTeam(id: target)
            } catch {
                if next == nil { throw error } // else a newer choice replaces the one that failed
            }
        }
    }

    /// The newest choice not saved yet, while a switch runs.
    @ObservationIgnored private var next: String?

    /// Re-reads the account's teams (one left, joined or deleted elsewhere), joining a read in flight. A selection
    /// the account no longer has falls back to its first team, and ``id`` changes with it (observable).
    public func refresh() async {
        guard source.isAuthenticated else { return }
        if let reading { return await reading.value }
        lastRead = now()
        let read = Task { await source.refreshTeams() }
        reading = read
        await read.value
        if reading == read { reading = nil }
    }

    /// How often cmux coming to the front, or a refusal for the same team, re-reads the teams.
    public static let rereadInterval: Duration = .seconds(60)

    /// cmux came to the front: re-reads the teams unless a read started in the last ``rereadInterval``.
    /// A team deleted on the web stopped being the selection only at the next sign-in (Leo, 2026-11-10).
    public func refreshIfStale() async {
        if reading == nil, let lastRead, lastRead.duration(to: now()) < Self.rereadInterval { return }
        await refresh()
    }

    /// A Cloud call in `team` (a Stack team id) was refused as not a member (`auth.forbidden`): re-reads the
    /// teams at once, so a team that is gone stops being the selection; one still listed stays, and the
    /// refusal shows as before. Only the active team counts, and the same team re-reads at most once per
    /// ``rereadInterval``, so a caller that keeps retrying never loops reads.
    public func teamRefused(_ team: String) async {
        guard team == id else { return }
        let at = now()
        if let lastRefusal, lastRefusal.team == team, lastRefusal.at.duration(to: at) < Self.rereadInterval { return }
        lastRefusal = (team, at)
        await refresh()
    }

    /// The read in flight, which a second ask joins.
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// When the last read started.
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    /// The last refused team that re-read, and when.
    @ObservationIgnored private var lastRefusal: (team: String, at: ContinuousClock.Instant)?
    /// The clock the throttles read (tests move it).
    @ObservationIgnored var now: @MainActor () -> ContinuousClock.Instant = { .now }
}

extension CloudAuth {
    /// A team mint for the backend `team` was refused with `auth.forbidden` (``MacInstallIdentity``): when that
    /// is the active team, re-read the account's teams (``ActiveTeam/teamRefused(_:)``).
    public func backendTeamRefused(_ team: String) async {
        guard let active = activeTeam.id, (try? accessTokenTeam(requested: nil)) == team else { return }
        await activeTeam.teamRefused(active)
    }
}
