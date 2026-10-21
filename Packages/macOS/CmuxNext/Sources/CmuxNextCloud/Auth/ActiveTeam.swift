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

    /// The account's teams this device may use.
    public var teams: [CMUXAuthTeam] {
        Self.allowedTeams(source.availableTeams, managed: managedTeamID)
    }

    /// The active team's id, or nil (signed out, no team, or the managed team missing).
    /// It can be set before ``teams`` loads: the cached selection stays in effect meanwhile.
    public var id: String? {
        Self.allowedTeamID(resolved: source.resolvedTeamID, available: source.availableTeams.map(\.id), managed: managedTeamID)
    }

    /// The active team, once membership has loaded.
    public var team: CMUXAuthTeam? {
        guard let id else { return nil }
        return teams.first { $0.id == id }
    }

    /// Whether the person can switch to another team here.
    public var canSwitch: Bool { managedTeamID == nil && teams.count > 1 && !isSwitching }

    /// Why a switch was refused.
    public enum Refusal: Error, Equatable, Sendable {
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
        let named = requested.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if let managed, active != managed || (named != nil && named != managed) { return .managed }
        if let named, named != active { return .notActive }
        return nil
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

    /// Re-reads the account's teams (one left or joined elsewhere).
    public func refresh() async {
        guard source.isAuthenticated else { return }
        await source.refreshTeams()
    }

    nonisolated static func allowedTeams(_ teams: [CMUXAuthTeam], managed: String?) -> [CMUXAuthTeam] {
        guard let managed else { return teams }
        return teams.filter { $0.id == managed }
    }

    /// The resolved team, or only the managed one (when the account belongs
    /// to it) while the device is restricted.
    nonisolated static func allowedTeamID(resolved: String?, available: [String], managed: String?) -> String? {
        guard let managed else { return resolved }
        return available.contains(managed) ? managed : nil
    }
}
