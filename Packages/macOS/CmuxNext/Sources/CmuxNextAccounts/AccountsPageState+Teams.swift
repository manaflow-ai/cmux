public import CMUXAuthCore
public import Foundation

/// The Teams part of the Accounts screen as the Settings page draws it: one
/// row per team with the person's role, the open team's details, and the
/// create, rename and delete forms, every text localized here.
extension AccountsPageState {
    /// An inline name form (New Team, Rename Team). Button ids: `submit`, `cancel`.
    public struct TeamForm: Encodable, Equatable, Sendable {
        /// `create` or `rename`.
        public let kind: String
        public let title: String
        public let help: String
        /// The name the field starts with.
        public let value: String
        public let placeholder: String
        public let maxLength: Int
        public let submit: String
        public let cancel: String
        public let error: String?
        public let busy: Bool
    }

    /// The delete confirmation, naming the team.
    public struct TeamConfirm: Encodable, Equatable, Sendable {
        public let text: String
        public let confirm: String
        public let cancel: String
        public let error: String?
        public let busy: Bool
    }

    public struct TeamFact: Encodable, Equatable, Sendable {
        public let label: String
        public let value: String
    }

    public struct TeamMember: Encodable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let detail: String?
        public let role: String
        /// "You" on the person's own row.
        public let you: String?
    }

    public struct TeamInvitation: Encodable, Equatable, Sendable {
        public let id: String
        public let email: String
        public let role: String
        public let expires: String?
    }

    /// The open team's details. Members see them read-only (`readOnly`);
    /// admins get Rename and Delete (`buttons`: `team.rename`, `team.delete`).
    public struct TeamDetails: Encodable, Equatable, Sendable {
        public let loading: String?
        public let error: String?
        public let facts: [TeamFact]
        public let membersTitle: String
        public let members: [TeamMember]
        /// Pending invitations; nil unless the person is an admin.
        public let invitationsTitle: String?
        public let invitations: [TeamInvitation]?
        public let noInvitations: String?
        public let buttons: [Button]
        public let readOnly: String?
        public let rename: TeamForm?
        public let confirm: TeamConfirm?
    }

    public struct TeamRow: Encodable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// Admin, Member, or Role unknown.
        public let role: String
        /// `admin`, `member` or `unknown`.
        public let roleKind: String
        /// "Active" on the active team.
        public let active: String?
        public let open: Bool
        /// Details or Hide Details (`team.details`).
        public let toggle: Button
        public let detail: TeamDetails?
    }

    /// The account's teams. `newTeam` runs `team.new`, which opens `create`.
    public struct TeamList: Encodable, Equatable, Sendable {
        public let title: String
        public let newTeam: Button
        public let rows: [TeamRow]
        public let empty: String?
        public let create: TeamForm?
        public let notice: Notice?
    }
}

extension AccountsPageAction {
    /// One gesture of the Teams part: the page sends `team.<raw value>` with `team` and `name` as needed.
    public enum TeamGesture: Equatable, Sendable {
        case details(String)
        case new
        case create(name: String)
        case rename(String)
        case saveName(String, name: String)
        case delete(String)
        case confirmDelete(String)
        case cancel

        /// Parses `details|new|create|rename|saveName|delete|confirmDelete|cancel`; nil when a field it needs is missing.
        public init?(action: String, team: String?, name: String?) {
            let team = team.flatMap { $0.isEmpty ? nil : $0 }
            switch (action, team, name) {
            case ("details", let team?, _): self = .details(team)
            case ("new", _, _): self = .new
            case ("create", _, let name?): self = .create(name: name)
            case ("rename", let team?, _): self = .rename(team)
            case ("saveName", let team?, let name?): self = .saveName(team, name: name)
            case ("delete", let team?, _): self = .delete(team)
            case ("confirmDelete", let team?, _): self = .confirmDelete(team)
            case ("cancel", _, _): self = .cancel
            default: return nil
            }
        }
    }
}

extension AccountsModel {
    /// Runs one Teams gesture; returns the failure text of a create, rename or delete, else nil.
    func perform(_ gesture: AccountsPageAction.TeamGesture) async -> String? {
        switch gesture {
        case .details(let id): await teamsModel.toggleDetails(id)
        case .new: teamsModel.beginCreate()
        case .create(let name): return await teamsModel.create(named: name)
        case .rename(let id): teamsModel.beginRename(id)
        case .saveName(let id, let name): return await teamsModel.rename(id, to: name)
        case .delete(let id): teamsModel.beginDelete(id)
        case .confirmDelete(let id): return await teamsModel.delete(id)
        case .cancel: teamsModel.cancelForm()
        }
        return nil
    }

    var pageTeamList: AccountsPageState.TeamList? {
        guard let active = services.activeTeam else { return nil }
        let model = teamsModel
        let activeID = active.id
        model.noteTeams(active.teams.map(\.id))
        let rows = active.teams.map { team in
            let role = model.role(of: team.id)
            let open = model.openTeamID == team.id
            return AccountsPageState.TeamRow(
                id: team.id, name: team.displayName, role: AccountsStrings.role(role), roleKind: role?.rawValue ?? "unknown",
                active: team.id == activeID ? AccountsStrings.teamsActive : nil, open: open,
                toggle: .init(id: "team.details", title: open ? AccountsStrings.teamsHideDetails : AccountsStrings.teamsDetails,
                              disabled: false, help: nil, destructive: false),
                detail: open ? pageTeamDetail(team) : nil)
        }
        return .init(
            title: AccountsStrings.teamsTitle,
            newTeam: .init(id: "team.new", title: AccountsStrings.teamsNew,
                           disabled: model.isSaving || active.managedTeamID != nil, help: nil, destructive: false),
            rows: rows, empty: rows.isEmpty ? AccountsStrings.teamsEmpty : nil,
            create: model.form == .create
                ? teamForm(kind: "create", title: AccountsStrings.teamsCreateTitle, help: AccountsStrings.teamsCreateHelp,
                           value: "", submit: AccountsStrings.teamsCreate) : nil,
            notice: model.notice.map { AccountsPageState.Notice(kind: "success", text: $0) })
    }

    private func pageTeamDetail(_ team: CMUXAuthTeam) -> AccountsPageState.TeamDetails {
        let model = teamsModel
        let membership = model.memberships[team.id]
        let rename = model.form == .rename(teamID: team.id)
            ? teamForm(kind: "rename", title: AccountsStrings.teamsRenameTitle, help: AccountsStrings.teamsNameHelp,
                       value: team.displayName, submit: AccountsStrings.teamsSave) : nil
        let confirm = model.form == .delete(teamID: team.id)
            ? AccountsPageState.TeamConfirm(text: AccountsStrings.teamsDeleteQuestion(team.displayName),
                                            confirm: AccountsStrings.teamsDeleteConfirm, cancel: AccountsStrings.cancel,
                                            error: model.formError, busy: model.isSaving) : nil
        guard case .loaded(let detail)? = model.detail else {
            let error: String? = if case .failed(let message)? = model.detail { message } else { nil }
            return .init(loading: error == nil ? AccountsStrings.teamsLoading : nil, error: error,
                         facts: [.init(label: AccountsStrings.teamsYourRole, value: AccountsStrings.role(membership?.role))],
                         membersTitle: AccountsStrings.teamsMembers, members: [], invitationsTitle: nil, invitations: nil,
                         noInvitations: nil, buttons: [], readOnly: nil, rename: rename, confirm: confirm)
        }
        let viewer = detail.viewer
        let isAdmin = viewer.role == .admin
        var facts = [AccountsPageState.TeamFact(label: AccountsStrings.teamsYourRole, value: AccountsStrings.role(viewer.role))]
        if let billing = detail.billing {
            facts.append(.init(label: AccountsStrings.teamsMemberCount,
                               value: AccountsStrings.teamsMemberCountValue(billing.memberCount, of: billing.memberLimit)))
            facts.append(.init(label: AccountsStrings.teamsPlan, value: AccountsStrings.plan(billing.planId)))
        }
        var buttons: [AccountsPageState.Button] = []
        let busy = model.isSaving || model.form != nil && model.form != .create
        if isAdmin, viewer.permissions.updateTeam {
            buttons.append(.init(id: "team.rename", title: AccountsStrings.teamsRename, disabled: busy, help: nil, destructive: false))
        }
        if isAdmin, viewer.permissions.deleteTeam {
            buttons.append(.init(id: "team.delete", title: AccountsStrings.teamsDelete, disabled: busy, help: nil, destructive: true))
        }
        let showsInvitations = isAdmin && viewer.permissions.inviteMembers
        return .init(
            loading: nil, error: nil, facts: facts,
            membersTitle: AccountsStrings.teamsMembers,
            members: detail.members.map { member -> AccountsPageState.TeamMember in
                let name = member.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? member.email ?? AccountsStrings.teamsUnnamedMember
                return AccountsPageState.TeamMember(id: member.userId, name: name, detail: name == member.email ? nil : member.email,
                             role: AccountsStrings.role(member.role), you: member.isViewer ? AccountsStrings.teamsYou : nil)
            },
            invitationsTitle: showsInvitations ? AccountsStrings.teamsInvitations : nil,
            invitations: showsInvitations ? detail.invitations.map { invitation in
                AccountsPageState.TeamInvitation(id: invitation.id, email: invitation.email ?? AccountsStrings.teamsInviteLink,
                      role: AccountsStrings.role(invitation.role),
                      expires: Self.expiryDate(invitation.expiresAt).map(AccountsStrings.teamsExpires))
            } : nil,
            noInvitations: showsInvitations && detail.invitations.isEmpty ? AccountsStrings.teamsNoInvitations : nil,
            buttons: buttons,
            readOnly: buttons.isEmpty ? AccountsStrings.teamsReadOnly : nil,
            rename: rename, confirm: confirm)
    }

    private func teamForm(kind: String, title: String, help: String, value: String, submit: String) -> AccountsPageState.TeamForm {
        .init(kind: kind, title: title, help: help, value: value, placeholder: AccountsStrings.teamsNamePlaceholder,
              maxLength: CMUXTeamName.maximumLength, submit: submit, cancel: AccountsStrings.cancel,
              error: teamsModel.formError, busy: teamsModel.isSaving)
    }

    /// The invitation's expiry as a short local date, or nil when the server's date does not parse.
    static func expiryDate(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? {
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: iso)
        }()
        return date?.formatted(date: .abbreviated, time: .omitted)
    }
}
