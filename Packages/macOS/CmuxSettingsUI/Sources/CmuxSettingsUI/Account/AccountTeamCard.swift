import AppKit
import Observation
import SwiftUI

/// The **Members** card under Account: who is on the selected team, pending
/// invitations and invite links, as plain rows in the same shape as the
/// identity row above. Every action goes through the host's
/// ``AccountTeamManagement`` implementation.
@MainActor
public struct AccountTeamCard: View {
    /// Posted by the host to expand the invite composer and focus its field,
    /// for example from the Cloud header's Invite button or the palette.
    public static let focusInviteRequestName = Notification.Name("cmux.settings.team.focusInvite")
    /// The search anchor the host navigates to when it opens this card.
    public static let searchAnchorID = "setting:account:team"

    @State private var model: AccountTeamCardModel
    @FocusState private var inviteFieldFocused: Bool

    public init(flow: AccountFlow) {
        _model = State(initialValue: AccountTeamCardModel(flow: flow))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.isComposingInvite, model.detail?.canInvite ?? false {
                Divider()
                inviteComposer
            }
            if let message = model.errorMessage ?? model.notice {
                Divider()
                Text(message)
                    .cmuxFont(size: 11)
                    .foregroundColor(model.errorMessage != nil ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier(model.errorMessage != nil ? "SettingsTeamError" : "SettingsTeamNotice")
            }
            if let detail = model.detail {
                Divider()
                rosterRows(detail)
                if detail.canInvite, !detail.invitations.isEmpty {
                    Divider()
                    invitationRows(detail.invitations)
                }
                if detail.canInvite, !detail.links.isEmpty {
                    Divider()
                    linkRows(detail.links)
                }
            } else if model.isLoading {
                Divider()
                loadingRow
            }
        }
        .onAppear { model.reloadIfNeeded() }
        .onChange(of: model.selectedTeamID) { _, _ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: Self.focusInviteRequestName)) { _ in
            model.isComposingInvite = true
            inviteFieldFocused = true
        }
        .accessibilityIdentifier("SettingsTeamCard")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.team.members", defaultValue: "Members"))
                    .cmuxFont(size: 13, weight: .medium)
                Text(model.subtitle)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsTeamSubtitle")
            }
            Spacer(minLength: 12)
            if model.detail?.canInvite ?? false {
                Button {
                    model.isComposingInvite.toggle()
                    if model.isComposingInvite { inviteFieldFocused = true }
                } label: {
                    Text(model.isComposingInvite
                        ? String(localized: "settings.team.invite.cancel", defaultValue: "Cancel")
                        : String(localized: "settings.team.invite.short", defaultValue: "Invite…"))
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTeamInviteButton")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The first fetch has nothing to show yet; later reloads keep the rows.
    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(String(localized: "settings.team.loading", defaultValue: "Loading members…"))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityIdentifier("SettingsTeamLoading")
    }

    // MARK: Invite composer

    private var inviteComposer: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "settings.team.invite.placeholder", defaultValue: "Email addresses, comma separated"),
                text: $model.inviteEmails
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($inviteFieldFocused)
            .onSubmit { model.submitInvite() }
            .disabled(model.isInviting)
            .accessibilityIdentifier("SettingsTeamInviteField")
            Picker("", selection: $model.inviteRole) {
                Text(String(localized: "settings.team.role.member", defaultValue: "Member")).tag(AccountTeamRole.member)
                Text(String(localized: "settings.team.role.admin", defaultValue: "Admin")).tag(AccountTeamRole.admin)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 88)
            .disabled(model.isInviting)
            .accessibilityLabel(String(localized: "settings.team.invite.roleLabel", defaultValue: "Invite role"))
            if model.isInviting {
                ProgressView().controlSize(.small).frame(width: 44)
            } else {
                Button(String(localized: "settings.team.invite.sendShort", defaultValue: "Send")) {
                    model.submitInvite()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSendInvite)
                .accessibilityIdentifier("SettingsTeamSendInvitesButton")
            }
            Button(String(localized: "settings.team.link.copyShort", defaultValue: "Copy link")) {
                model.copyInviteLink()
            }
            .controlSize(.small)
            .disabled(model.isInviting)
            .accessibilityIdentifier("SettingsTeamCopyLinkButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Rows

    private func rosterRows(_ detail: AccountTeamDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(detail.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider().padding(.leading, 14) }
                memberRow(member, detail: detail)
            }
        }
    }

    private func memberRow(_ member: AccountTeamMember, detail: AccountTeamDetail) -> some View {
        let pending = model.pendingID == member.id
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.label).cmuxFont(size: 13, weight: .medium).lineLimit(1)
                    if member.isViewer {
                        Text(String(localized: "settings.team.you", defaultValue: "you"))
                            .cmuxFont(size: 11)
                            .foregroundColor(.secondary)
                    }
                }
                if let email = member.email, email != member.label {
                    Text(email).cmuxFont(size: 11).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if pending {
                ProgressView().controlSize(.small)
            } else {
                if detail.canInvite, !member.isViewer {
                    Picker("", selection: Binding(
                        get: { member.role },
                        set: { model.setRole($0, for: member) }
                    )) {
                        Text(String(localized: "settings.team.role.member", defaultValue: "Member")).tag(AccountTeamRole.member)
                        Text(String(localized: "settings.team.role.admin", defaultValue: "Admin")).tag(AccountTeamRole.admin)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 88)
                    .accessibilityLabel(String(localized: "settings.team.invite.roleLabel", defaultValue: "Invite role"))
                } else {
                    Text(roleTitle(member.role))
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary)
                }
                if member.isViewer {
                    if detail.members.count > 1 {
                        Button(String(localized: "settings.team.leave", defaultValue: "Leave")) {
                            model.remove(member)
                        }
                        .controlSize(.small)
                    }
                } else if detail.canRemoveMembers {
                    Button(String(localized: "settings.team.removeShort", defaultValue: "Remove")) {
                        model.remove(member)
                    }
                    .controlSize(.small)
                    .accessibilityLabel(String(
                        format: String(localized: "settings.team.remove", defaultValue: "Remove %@"),
                        member.label
                    ))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityIdentifier("SettingsTeamMember_\(member.userID)")
    }

    private func invitationRows(_ invitations: [AccountTeamInvitation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(String(localized: "settings.team.section.invitations", defaultValue: "Pending invitations"))
            ForEach(invitations) { invitation in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.email ?? invitation.id).cmuxFont(size: 13, weight: .medium).lineLimit(1)
                        Text(roleTitle(invitation.role)).cmuxFont(size: 11).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 12)
                    revokeControl(id: invitation.id) { model.revoke(invitation) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityIdentifier("SettingsTeamInvitation_\(invitation.id)")
            }
        }
    }

    private func linkRows(_ links: [AccountTeamInviteLink]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(String(localized: "settings.team.section.links", defaultValue: "Invite links"))
            ForEach(links) { link in
                HStack(alignment: .center, spacing: 12) {
                    Text(model.linkSummary(link)).cmuxFont(size: 13, weight: .medium).lineLimit(1)
                    Spacer(minLength: 12)
                    revokeControl(id: link.id) { model.revoke(link) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityIdentifier("SettingsTeamInviteLink_\(link.id)")
            }
        }
    }

    @ViewBuilder
    private func revokeControl(id: String, action: @escaping () -> Void) -> some View {
        if model.pendingID == id {
            ProgressView().controlSize(.small)
        } else {
            Button(String(localized: "settings.team.revoke", defaultValue: "Revoke"), action: action)
                .controlSize(.small)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .cmuxFont(size: 11)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
    }

    private func roleTitle(_ role: AccountTeamRole) -> String {
        role == .admin
            ? String(localized: "settings.team.role.admin", defaultValue: "Admin")
            : String(localized: "settings.team.role.member", defaultValue: "Member")
    }
}

/// View state for the Members card. One mutation path (`run`) marks the row
/// it acts on, reloads the roster after success and maps failures through
/// the host. Rows stay visible and usable during a reload.
@MainActor
@Observable
final class AccountTeamCardModel {
    private let flow: AccountFlow
    var detail: AccountTeamDetail?
    var isLoading = false
    var isComposingInvite = false
    var errorMessage: String?
    var notice: String?
    var inviteEmails = ""
    var inviteRole: AccountTeamRole = .member
    /// The member, invitation or link id whose action is in flight, or the
    /// composer's marker while an invite or link request runs.
    var pendingID: String?
    @ObservationIgnored private var loadedTeamID: String?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    static let composerPendingID = "composer"

    init(flow: AccountFlow) {
        self.flow = flow
    }

    var selectedTeamID: String? { flow.selectedTeamID }
    var isInviting: Bool { pendingID == Self.composerPendingID }
    var canSendInvite: Bool {
        pendingID == nil && !inviteEmails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "Lawrence Chen's Team · 2 of 3 seats used" or the member count.
    var subtitle: String {
        guard let detail else {
            return isLoading
                ? String(localized: "settings.team.loading", defaultValue: "Loading members…")
                : String(localized: "settings.team.subtitle.empty", defaultValue: "People who share this team's Cloud machines.")
        }
        if let limit = detail.memberLimit {
            return String(
                format: String(localized: "settings.team.seatSummary", defaultValue: "%1$@ · %2$d of %3$d seats used"),
                detail.teamName,
                detail.seatsUsed,
                limit
            )
        }
        return String(
            format: String(localized: "settings.team.memberCount", defaultValue: "%1$@ · %2$d members"),
            detail.teamName,
            detail.members.count
        )
    }

    func reloadIfNeeded() {
        guard detail == nil || loadedTeamID != flow.selectedTeamID else { return }
        reload()
    }

    func reload() {
        guard flow.supportsTeamManagement, flow.selectedTeamID != nil else {
            detail = nil
            return
        }
        reloadTask?.cancel()
        isLoading = true
        let teamID = flow.selectedTeamID
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isLoading = false }
            do {
                let loaded = try await flow.loadTeamDetail()
                guard !Task.isCancelled else { return }
                detail = loaded
                loadedTeamID = teamID
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                errorMessage = flow.teamManagementMessage(for: error)
            }
        }
    }

    func submitInvite() {
        let emails = inviteEmails
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !emails.isEmpty else { return }
        run(id: Self.composerPendingID) { [self] in
            let outcome = try await flow.inviteTeamMembers(emails: emails, role: inviteRole)
            if outcome.failedEmails.isEmpty {
                inviteEmails = ""
                isComposingInvite = false
                notice = String(localized: "settings.team.invite.sent", defaultValue: "Invitations sent.")
            } else {
                inviteEmails = outcome.failedEmails.joined(separator: ", ")
                notice = String(
                    format: String(localized: "settings.team.invite.partial", defaultValue: "Could not invite: %@"),
                    outcome.failedEmails.joined(separator: ", ")
                )
            }
        }
    }

    func copyInviteLink() {
        run(id: Self.composerPendingID) { [self] in
            let created = try await flow.createTeamInviteLink()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(created.url, forType: .string)
            notice = String(localized: "settings.team.link.copied", defaultValue: "Invite link copied. It expires in 7 days.")
        }
    }

    func revoke(_ invitation: AccountTeamInvitation) {
        run(id: invitation.id) { [self] in
            try await flow.revokeTeamInvitation(id: invitation.id)
            notice = nil
        }
    }

    func revoke(_ link: AccountTeamInviteLink) {
        run(id: link.id) { [self] in
            try await flow.revokeTeamInviteLink(id: link.id)
            notice = nil
        }
    }

    func remove(_ member: AccountTeamMember) {
        run(id: member.id) { [self] in
            try await flow.removeTeamMember(userID: member.userID)
        }
    }

    func setRole(_ role: AccountTeamRole, for member: AccountTeamMember) {
        guard role != member.role else { return }
        run(id: member.id) { [self] in
            try await flow.changeTeamMemberRole(userID: member.userID, role: role)
        }
    }

    func linkSummary(_ link: AccountTeamInviteLink) -> String {
        let uses: String
        if let maxUses = link.maxUses {
            uses = String(
                format: String(localized: "settings.team.link.usesOf", defaultValue: "%1$d of %2$d uses"),
                link.useCount,
                maxUses
            )
        } else {
            uses = String(
                format: String(localized: "settings.team.link.uses", defaultValue: "%d uses"),
                link.useCount
            )
        }
        guard let expiresAt = link.expiresAt else { return uses }
        return String(
            format: String(localized: "settings.team.link.summary", defaultValue: "%1$@ · expires %2$@"),
            uses,
            expiresAt.formatted(date: .abbreviated, time: .omitted)
        )
    }

    /// Runs one action with its row marked pending. A second action waits
    /// until the first finishes so the roster never reloads mid-mutation.
    private func run(id: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard pendingID == nil else { return }
        pendingID = id
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await action()
                pendingID = nil
                reload()
            } catch {
                pendingID = nil
                errorMessage = flow.teamManagementMessage(for: error)
            }
        }
    }
}
