public import CMUXAuthCore
public import Foundation
public import Observation

/// The Teams part of the Accounts screen: the person's role in each team,
/// the one team whose details are open, and the create, rename and delete
/// forms. The team list itself is the active team's (``ActiveTeam/teams``),
/// which the auth coordinator updates after every change, so the list,
/// the active team and everything that follows it never disagree.
/// Nothing polls: roles re-read on Refresh and after each change.
@MainActor
@Observable
public final class AccountsTeamsModel {
    /// The inline form that is open.
    public enum Form: Equatable, Sendable {
        case create
        case rename(teamID: String)
        case delete(teamID: String)
    }

    /// The open team's details.
    public enum Detail: Equatable, Sendable {
        case loading
        case loaded(CMUXTeamDetail)
        case failed(String)
    }

    /// The person's membership of each team by id, with roles when known.
    public private(set) var memberships: [String: CMUXTeamMembership] = [:]
    /// The team whose details are open.
    public private(set) var openTeamID: String?
    /// The open team's details.
    public private(set) var detail: Detail?
    public private(set) var form: Form?
    /// Why the open form's last submit failed.
    public private(set) var formError: String?
    /// A create, rename or delete is being saved.
    public private(set) var isSaving = false
    /// What the last change did, until the next gesture.
    public private(set) var notice: String?

    @ObservationIgnored private let services: any AccountsServices
    @ObservationIgnored private var membershipRead = 0
    /// Teams a role read was already started for, so a team the server does
    /// not list (roles unknown) asks once, not on every redraw.
    @ObservationIgnored private var askedFor: Set<String> = []
    @ObservationIgnored private var detailRead = 0

    init(services: any AccountsServices) {
        self.services = services
    }

    /// The person's role in `teamID`, nil when unknown.
    public func role(of teamID: String) -> CMUXTeamRole? { memberships[teamID]?.role }

    /// The team list changed (a team made from the palette, an invitation
    /// accepted in the browser, another account): re-reads the roles once for
    /// teams it has none for. The page calls it as it draws the list, so the
    /// read follows the list's own change, never a timer.
    func noteTeams(_ ids: [String]) {
        let unknown = Set(ids).subtracting(memberships.keys).subtracting(askedFor)
        guard !unknown.isEmpty else { return }
        askedFor.formUnion(unknown)
        // task-owner: one role read for a membership change; reload drops a superseded answer.
        Task { await reload() }
    }

    /// Re-reads the roles, then the open details. A newer read supersedes an
    /// older one; a failed read keeps the roles last shown.
    public func reload() async {
        guard services.activeTeam != nil else {
            memberships = [:]
            askedFor = []
            close()
            return
        }
        membershipRead += 1
        let read = membershipRead
        if let list = try? await services.teamBackend?.teamMemberships(), read == membershipRead {
            memberships = Dictionary(list.teams.map { ($0.id, $0) }) { first, _ in first }
        }
        if let openTeamID { await loadDetail(openTeamID) }
    }

    /// Opens `teamID`'s details, or closes them when they are open.
    public func toggleDetails(_ teamID: String) async {
        notice = nil
        if openTeamID == teamID {
            close()
            return
        }
        openTeamID = teamID
        detail = .loading
        if form != .create { form = nil }
        formError = nil
        await loadDetail(teamID)
    }

    public func beginCreate() {
        notice = nil
        formError = nil
        form = .create
    }

    public func beginRename(_ teamID: String) {
        notice = nil
        formError = nil
        form = .rename(teamID: teamID)
    }

    public func beginDelete(_ teamID: String) {
        notice = nil
        formError = nil
        form = .delete(teamID: teamID)
    }

    public func cancelForm() {
        guard !isSaving else { return }
        form = nil
        formError = nil
    }

    /// Creates a team named `name`; it becomes the active team. Returns the
    /// failure text, or nil.
    @discardableResult
    public func create(named name: String) async -> String? {
        await save(.create) {
            let team = try await self.backend().createTeam(named: try Self.validName(name))
            return AccountsStrings.teamsCreated(team.displayName)
        }
    }

    /// Renames `teamID` (admins only). Returns the failure text, or nil.
    @discardableResult
    public func rename(_ teamID: String, to name: String) async -> String? {
        await save(.rename(teamID: teamID)) {
            let valid = try Self.validName(name)
            try await self.backend().renameTeam(id: teamID, to: valid)
            return AccountsStrings.teamsRenamed(valid)
        }
    }

    /// Deletes `teamID` (admins only). When it was the active team, the auth
    /// coordinator makes another team active. Returns the failure text, or nil.
    @discardableResult
    public func delete(_ teamID: String) async -> String? {
        let name = services.activeTeam?.teams.first { $0.id == teamID }?.displayName ?? memberships[teamID]?.displayName ?? ""
        let wasActive = services.activeTeam?.id == teamID
        return await save(.delete(teamID: teamID)) {
            try await self.backend().deleteTeam(id: teamID)
            if self.openTeamID == teamID { self.close() }
            if wasActive, let now = self.services.activeTeam?.team {
                return AccountsStrings.teamsDeletedActive(name, now: now.displayName)
            }
            return AccountsStrings.teamsDeleted(name)
        }
    }

    /// Runs one change of `form`: the form stays open with the failure, or
    /// closes with the outcome and the roles re-read.
    private func save(_ form: Form, _ work: @escaping () async throws -> String) async -> String? {
        guard !isSaving else {
            if self.form == form { formError = AccountsStrings.teamsErrorBusy }
            return AccountsStrings.teamsErrorBusy
        }
        self.form = form
        formError = nil
        notice = nil
        isSaving = true
        do {
            let outcome = try await work()
            isSaving = false
            if self.form == form { self.form = nil }
            notice = outcome
            await reload()
            return nil
        } catch {
            isSaving = false
            let message = AccountsStrings.teamMessage(for: error)
            if self.form == form { formError = message }
            // A team that is gone leaves the list on the next read.
            if (error as? CMUXTeamError) == .notFound {
                await services.activeTeam?.refresh()
                await reload()
            }
            return message
        }
    }

    private func loadDetail(_ teamID: String) async {
        detailRead += 1
        let read = detailRead
        do {
            let loaded = try await backend().teamDetail(id: teamID)
            guard read == detailRead, openTeamID == teamID else { return }
            detail = .loaded(loaded)
        } catch {
            guard read == detailRead, openTeamID == teamID else { return }
            detail = .failed(AccountsStrings.teamMessage(for: error))
        }
    }

    private func close() {
        openTeamID = nil
        detail = nil
        if case .rename = form { form = nil; formError = nil }
        if case .delete = form { form = nil; formError = nil }
    }

    private func backend() throws -> any AccountsTeamBackend {
        guard let backend = services.teamBackend else { throw CMUXTeamError.unavailable }
        return backend
    }

    private static func validName(_ name: String) throws -> String {
        try CMUXTeamName(name).value
    }
}
