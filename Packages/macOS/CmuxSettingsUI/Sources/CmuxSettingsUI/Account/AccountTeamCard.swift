import AppKit
import Observation
import SwiftUI

/// The **Team** card under Account: who is on the selected team, a prominent
/// Invite button, pending invitations and invite links. Every action goes
/// through the host's ``AccountTeamManagement`` implementation.
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
                Divider().padding(.horizontal, 14)
                inviteComposer
            }
            if let message = model.errorMessage ?? model.notice {
                Divider().padding(.horizontal, 14)
                Text(message)
                    .cmuxFont(size: 11)
                    .foregroundColor(model.errorMessage != nil ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier(model.errorMessage != nil ? "SettingsTeamError" : "SettingsTeamNotice")
            }
            if let detail = model.detail {
                Divider().padding(.horizontal, 14)
                rosterRows(detail)
                if detail.canInvite, !detail.invitations.isEmpty {
                    Divider().padding(.horizontal, 14)
                    invitationRows(detail.invitations)
                }
                if detail.canInvite, !detail.links.isEmpty {
                    Divider().padding(.horizontal, 14)
                    linkRows(detail.links)
                }
            }
        }
        .disabled(model.isSubmitting)
        .onAppear { model.reloadIfNeeded() }
        .onChange(of: model.selectedTeamID) { _, _ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: Self.focusInviteRequestName)) { _ in
            model.isComposingInvite = true
            inviteFieldFocused = true
        }
        .accessibilityIdentifier("SettingsTeamCard")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "settings.team.title", defaultValue: "Team members"))
                    .cmuxFont(size: 13, weight: .medium)
                Text(model.subtitle)
                    .cmuxFont(size: 11)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SettingsTeamSubtitle")
            }
            Spacer(minLength: 12)
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .accessibilityLabel(String(localized: "settings.team.refresh", defaultValue: "Refresh members"))
            }
            if model.detail?.canInvite ?? false {
                Button {
                    model.isComposingInvite.toggle()
                    if model.isComposingInvite { inviteFieldFocused = true }
                } label: {
                    Label(
                        String(localized: "settings.team.invite", defaultValue: "Invite people"),
                        systemImage: "person.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTeamInviteButton")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var inviteComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "settings.team.invite.placeholder", defaultValue: "Email addresses, comma separated"),
                    text: $model.inviteEmails
                )
                .textFieldStyle(.roundedBorder)
                .focused($inviteFieldFocused)
                .onSubmit { model.submitInvite() }
                .accessibilityIdentifier("SettingsTeamInviteField")
                Picker("", selection: $model.inviteRole) {
                    Text(String(localized: "settings.team.role.member", defaultValue: "Member")).tag(AccountTeamRole.member)
                    Text(String(localized: "settings.team.role.admin", defaultValue: "Admin")).tag(AccountTeamRole.admin)
                }
                .labelsHidden()
                .frame(width: 96)
                .accessibilityLabel(String(localized: "settings.team.invite.roleLabel", defaultValue: "Invite role"))
                Button(String(localized: "settings.team.invite.send", defaultValue: "Send invites")) {
                    model.submitInvite()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.inviteEmails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("SettingsTeamSendInvitesButton")
            }
            HStack(spacing: 8) {
                Button {
                    model.copyInviteLink()
                } label: {
                    Label(
                        String(localized: "settings.team.link.copy", defaultValue: "Copy invite link"),
                        systemImage: "link"
                    )
                }
                .controlSize(.small)
                .accessibilityIdentifier("SettingsTeamCopyLinkButton")
                if let url = model.lastInviteLinkURL {
                    Text(url)
                        .cmuxFont(size: 11)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func rosterRows(_ detail: AccountTeamDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(detail.members.enumerated()), id: \.element.id) { index, member in
                if index > 0 { Divider().padding(.leading, 44) }
                memberRow(member, detail: detail)
            }
        }
    }

    private func memberRow(_ member: AccountTeamMember, detail: AccountTeamDetail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: member.role == .admin ? "person.badge.key" : "person")
                .foregroundColor(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(member.label).cmuxFont(size: 12).lineLimit(1)
                    if member.isViewer {
                        Text(String(localized: "settings.team.you", defaultValue: "you"))
                            .cmuxFont(size: 10)
                            .foregroundColor(.secondary)
                    }
                }
                if let email = member.email, email != member.label {
                    Text(email).cmuxFont(size: 11).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
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
                .frame(width: 96)
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
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundColor(.red)
                }
            } else if detail.canRemoveMembers {
                Button {
                    model.remove(member)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
                .accessibilityLabel(String(
                    format: String(localized: "settings.team.remove", defaultValue: "Remove %@"),
                    member.label
                ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityIdentifier("SettingsTeamMember_\(member.userID)")
    }

    private func invitationRows(_ invitations: [AccountTeamInvitation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(String(localized: "settings.team.section.invitations", defaultValue: "Pending invitations"))
            ForEach(invitations) { invitation in
                HStack(spacing: 10) {
                    Image(systemName: "envelope").foregroundColor(.secondary).frame(width: 18)
                    Text(invitation.email ?? invitation.id).cmuxFont(size: 12).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(roleTitle(invitation.role)).cmuxFont(size: 11).foregroundColor(.secondary)
                    Button(String(localized: "settings.team.revoke", defaultValue: "Revoke")) {
                        model.revoke(invitation)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .accessibilityIdentifier("SettingsTeamInvitation_\(invitation.id)")
            }
        }
    }

    private func linkRows(_ links: [AccountTeamInviteLink]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(String(localized: "settings.team.section.links", defaultValue: "Invite links"))
            ForEach(links) { link in
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundColor(.secondary).frame(width: 18)
                    Text(model.linkSummary(link)).cmuxFont(size: 12).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(String(localized: "settings.team.revoke", defaultValue: "Revoke")) {
                        model.revoke(link)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .accessibilityIdentifier("SettingsTeamInviteLink_\(link.id)")
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .cmuxFont(size: 11, weight: .medium)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func roleTitle(_ role: AccountTeamRole) -> String {
        role == .admin
            ? String(localized: "settings.team.role.admin", defaultValue: "Admin")
            : String(localized: "settings.team.role.member", defaultValue: "Member")
    }
}

/// View state for the Team card. One mutation path (`run`) reloads the roster
/// after every successful action and maps failures through the host.
@MainActor
@Observable
final class AccountTeamCardModel {
    private let flow: AccountFlow
    var detail: AccountTeamDetail?
    var isLoading = false
    var isSubmitting = false
    var isComposingInvite = false
    var errorMessage: String?
    var notice: String?
    var inviteEmails = ""
    var inviteRole: AccountTeamRole = .member
    var lastInviteLinkURL: String?
    @ObservationIgnored private var loadedTeamID: String?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(flow: AccountFlow) {
        self.flow = flow
    }

    var selectedTeamID: String? { flow.selectedTeamID }

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
        run { [self] in
            let outcome = try await flow.inviteTeamMembers(emails: emails, role: inviteRole)
            if outcome.failedEmails.isEmpty {
                inviteEmails = ""
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
        run { [self] in
            let created = try await flow.createTeamInviteLink()
            lastInviteLinkURL = created.url
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(created.url, forType: .string)
            notice = String(localized: "settings.team.link.copied", defaultValue: "Invite link copied. It expires in 7 days.")
        }
    }

    func revoke(_ invitation: AccountTeamInvitation) {
        run { [self] in
            try await flow.revokeTeamInvitation(id: invitation.id)
            notice = nil
        }
    }

    func revoke(_ link: AccountTeamInviteLink) {
        run { [self] in
            try await flow.revokeTeamInviteLink(id: link.id)
            lastInviteLinkURL = nil
        }
    }

    func remove(_ member: AccountTeamMember) {
        run { [self] in
            try await flow.removeTeamMember(userID: member.userID)
        }
    }

    func setRole(_ role: AccountTeamRole, for member: AccountTeamMember) {
        guard role != member.role else { return }
        run { [self] in
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

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSubmitting = false }
            do {
                try await action()
                reload()
            } catch {
                errorMessage = flow.teamManagementMessage(for: error)
            }
        }
    }
}
