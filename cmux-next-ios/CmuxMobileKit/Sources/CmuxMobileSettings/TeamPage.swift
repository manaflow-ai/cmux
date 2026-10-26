#if os(iOS)
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Settings → a team (pushed; back and the edge swipe return): its color and
/// icon, your role, the members with their roles, pending invitations and
/// the plan for admins, and Rename and Delete for admins. Members see it read
/// only. Everything comes from the cmux team API, the Mac app's backend;
/// changes go back to the owner (`renamed`, `deleted`), which refreshes the
/// team list.
struct TeamPage: View {
    let team: Team
    let auth: CmuxMobileAuthModel
    let edit: () -> Void
    let invite: () -> Void
    let renamed: (String, String) -> Void
    let deleted: (String) -> Void
    @State private var model: TeamDetailModel?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmsDelete = false

    private var detail: TeamDetail? { model?.detail }

    var body: some View {
        List {
            Section {
                Button(action: edit) {
                    // Avatars centered on the icon column: every title, header
                    // and footer on the page starts at one x.
                    CmuxMobileGutterRow {
                        SettingsTeamAvatar(team: team, size: 28)
                    } content: {
                        HStack {
                            Text("Color and icon").font(theme.type.rowTitle).foregroundStyle(theme.colors.label)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.colors.label3)
                        }
                    }
                }
                if let role = detail?.role {
                    SettingsLabel("Your role", symbol: role == .admin ? "person.badge.key" : "person", value: role.title)
                        .accessibilityIdentifier("team.role")
                }
            } footer: {
                Text("Color and icon are yours only; teammates choose their own.").cmuxMobileTextColumn()
            }
            membersSection
            if let detail, detail.isAdmin, !detail.invitations.isEmpty {
                invitationsSection(detail.invitations)
            }
            if let billing = detail?.billing {
                planSection(billing)
            }
            // The personal space is just you: nobody to invite.
            if !team.isPersonalSpace {
                Section {
                    Button(action: invite) {
                        SettingsLabel("Invite to team", symbol: "person.badge.plus")
                    }
                }
            }
            manageSection
        }
        .settingsPage(LocalizedStringKey(team.name))
        .task(id: team.id) {
            let model = TeamDetailModel(teamID: team.id, service: auth.teamService)
            model.onRenamed = { id, name in renamed(id, name) }
            model.onDeleted = { id in deleted(id) }
            self.model = model
            await model.load()
        }
        .refreshable { await model?.load() }
        .alert("Rename team", isPresented: $renaming) {
            TextField("Team name", text: $newName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("team.rename.field")
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = newName
                Task { await model?.rename(to: name) }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(deleteTitle, role: .destructive) {
                Task { await model?.delete() }
            }
            .accessibilityIdentifier("team.delete.confirm")
        } message: {
            Text("\(detail?.name ?? team.name) is deleted for every member, with its Macs and invitations. This can't be undone.")
        }
        #if DEBUG
        .onChange(of: TeamPageScript.shared.requestCount) { _, _ in
            guard let step = TeamPageScript.shared.request?.step else { return }
            play(step)
        }
        #endif
        .alert(actionErrorTitle, isPresented: Binding(
            get: { model?.actionError != nil },
            set: { if !$0 { model?.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model?.actionError ?? "")
        }
    }

    #if DEBUG
    private func play(_ step: TeamPageScript.Step) {
        switch step {
        case .showRename(let name):
            newName = name
            renaming = true
        case .commitRename:
            renaming = false
            let name = newName
            Task { await model?.rename(to: name) }
        case .showDelete:
            confirmsDelete = true
        case .commitDelete:
            confirmsDelete = false
            Task { await model?.delete() }
        case .dismiss:
            renaming = false
            confirmsDelete = false
            model?.actionError = nil
        }
    }
    #endif

    private var deleteTitle: String {
        String(localized: "Delete \(detail?.name ?? team.name)?")
    }

    private var actionErrorTitle: String {
        String(localized: "Couldn't change the team")
    }

    @ViewBuilder private var membersSection: some View {
        Section {
            switch model?.phase ?? .loading {
            case .loading:
                CmuxMobileGutterRow {
                    ProgressView()
                } content: {
                    Text("Loading members").foregroundStyle(theme.colors.label2)
                }
            case .failed(let message):
                SettingsLoadError(message: message) { Task { await model?.load() } }
            case .loaded(let detail):
                ForEach(detail.members) { member in
                    memberRow(member)
                }
            }
        } header: {
            Text("Members").cmuxMobileTextColumn()
        }
    }

    private func memberRow(_ member: TeamDetail.Member) -> some View {
        CmuxMobileGutterRow {
            UserInitials(member.initials, size: 28)
        } content: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.name).font(theme.type.rowTitle).lineLimit(1)
                        if member.isYou {
                            Text("You").font(theme.type.meta).foregroundStyle(theme.colors.label2)
                        }
                    }
                    if let email = member.email, email != member.name {
                        EmailText(email).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                    }
                }
                Spacer(minLength: 8)
                if let role = member.role {
                    Text(role.title).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func invitationsSection(_ invitations: [TeamDetail.Invitation]) -> some View {
        Section {
            ForEach(invitations) { invitation in
                CmuxMobileGutterRow {
                    SettingsIcon("envelope").foregroundStyle(theme.colors.label2).accessibilityHidden(true)
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.email ?? String(localized: "Invite link")).font(theme.type.rowTitle).lineLimit(1)
                        if let expiresAt = invitation.expiresAt {
                            Text("Expires \(expiresAt, format: .relative(presentation: .named))")
                                .font(theme.type.meta).foregroundStyle(theme.colors.label2)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Pending invitations").cmuxMobileTextColumn()
        }
    }

    private func planSection(_ billing: TeamDetail.Billing) -> some View {
        Section {
            if let plan = billing.planTitle {
                SettingsLabel("Plan", symbol: "creditcard", value: plan)
            }
            SettingsLabel("Members", symbol: "person.2", value: billing.memberCountText)
        }
    }

    @ViewBuilder private var manageSection: some View {
        if let detail, detail.canRename || detail.canDelete {
            Section {
                if detail.canRename {
                    Button {
                        newName = detail.name
                        renaming = true
                    } label: {
                        SettingsLabel("Rename team", symbol: "pencil")
                    }
                    .disabled(model?.isWorking == true)
                    .accessibilityIdentifier("team.rename")
                }
                if detail.canDelete {
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        CmuxMobileGutterRow {
                            SettingsIcon("trash").accessibilityHidden(true)
                        } content: {
                            HStack {
                                Text("Delete team").font(theme.type.rowTitle)
                                Spacer()
                                if model?.isWorking == true { ProgressView() }
                            }
                        }
                        .foregroundStyle(theme.colors.danger)
                    }
                    .disabled(model?.isWorking == true)
                    .accessibilityIdentifier("team.delete")
                }
            } footer: {
                if detail.canDelete, detail.billing?.hasActiveSubscription == true {
                    Text("This team has an active subscription. Cancel it on cmux.com before deleting the team.").cmuxMobileTextColumn()
                } else {
                    Text("Deleting a team removes it for every member.").cmuxMobileTextColumn()
                }
            }
        } else if let detail, detail.role == .member {
            Section {
            } footer: {
                Text("Only team admins can rename or delete this team.").cmuxMobileTextColumn()
            }
        } else if let detail, detail.role == nil, !team.isPersonalSpace {
            Section {
            } footer: {
                Text("Couldn't reach cmux, so roles and team changes aren't available right now.").cmuxMobileTextColumn()
            }
        }
    }
}
#endif

#if os(iOS) && DEBUG
/// DEBUG recordings (`-cmux-mobile-demo teams`): DemoDriver walks the team
/// page through its rename and delete dialogs, which the page owns.
@MainActor
@Observable
public final class TeamPageScript {
    public enum Step: Equatable, Sendable {
        case showRename(String), commitRename, showDelete, commitDelete, dismiss
    }

    public static let shared = TeamPageScript()
    /// The step to play, with a count so the same step plays again.
    public private(set) var request: (step: Step, count: Int)?

    public func play(_ step: Step) {
        request = (step, (request?.count ?? 0) + 1)
    }

    var requestCount: Int { request?.count ?? 0 }
}
#endif
