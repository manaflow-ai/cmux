import AppKit
import CmuxCloud
import SwiftUI

/// The members-and-invites window for the active Cloud team. One instance per
/// app, opened from the Cloud team picker, Settings, the command palette and
/// the `auth.team.open_members` socket method; released when closed.
@MainActor
final class CloudTeamMembersWindowController: ReleasingWindowController {
    private let accountFlow: HostAccountFlow
    private let model: CloudTeamMembersModel
    private let onClose: () -> Void

    init(accountFlow: HostAccountFlow, onClose: @escaping () -> Void) {
        self.accountFlow = accountFlow
        self.model = CloudTeamMembersModel(accountFlow: accountFlow)
        self.onClose = onClose
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "teamMembers.window.title", defaultValue: "Team Members")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.cloudTeamMembers")
        window.minSize = NSSize(width: 440, height: 360)
        window.isMovableByWindowBackground = true
        window.isFloatingPanel = false
        window.contentView = NSHostingView(rootView: CloudTeamMembersView(model: model))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    override func managedWindowWillClose(_ window: NSWindow) {
        onClose()
    }

    func show(focusInvite: Bool) {
        model.focusInviteRequest &+= 1
        if !focusInvite { model.focusInviteRequest = 0 }
        showManagedWindow(activateApplication: true, orderFrontRegardless: true)
        window?.makeKey()
        model.reload()
    }
}

/// View state for one team's roster. Every mutation goes through
/// ``HostAccountFlow`` so the window, socket and CLI share one path.
@MainActor
@Observable
final class CloudTeamMembersModel {
    private let accountFlow: HostAccountFlow
    var detail: CloudTeamDetail?
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?
    var notice: String?
    var inviteEmails = ""
    var inviteRole: CloudTeamRole = .member
    var lastInviteLinkURL: String?
    /// Incremented when a caller wants the invite field focused on show.
    var focusInviteRequest: UInt = 0
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init(accountFlow: HostAccountFlow) {
        self.accountFlow = accountFlow
    }

    var teamName: String {
        detail?.team.displayName
            ?? accountFlow.activeTeamDisplayName
            ?? String(localized: "sidebar.account.noTeam", defaultValue: "No team")
    }

    var currentUserID: String? { detail?.viewer.userId }

    /// "2 of 3 seats used" for capped personal plans; nil when uncapped.
    var seatSummary: String? {
        guard let detail, let limit = detail.billing.memberLimit else { return nil }
        let used = detail.members.count + detail.invitations.count
        return String(
            format: String(localized: "teamMembers.seatSummary", defaultValue: "%1$d of %2$d seats used"),
            used,
            limit
        )
    }

    func reload() {
        reloadTask?.cancel()
        isLoading = true
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isLoading = false }
            do {
                let loaded = try await accountFlow.loadTeamDetail()
                guard !Task.isCancelled else { return }
                detail = loaded
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                errorMessage = HostAccountFlow.teamMembersUserMessage(error)
            }
        }
    }

    func submitInvite() {
        let emails = inviteEmails
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !emails.isEmpty else {
            errorMessage = HostAccountFlow.teamMembersUserMessage(TeamsClientError.invalidEmail)
            return
        }
        run { [self] in
            let result = try await accountFlow.inviteTeamMembers(emails: emails, role: inviteRole)
            if result.failed.isEmpty {
                inviteEmails = ""
                notice = String(localized: "teamMembers.invite.sent", defaultValue: "Invitations sent.")
            } else {
                let failedEmails = result.failed.map(\.email).joined(separator: ", ")
                notice = String(
                    format: String(localized: "teamMembers.invite.partial", defaultValue: "Could not invite: %@"),
                    failedEmails
                )
                inviteEmails = failedEmails
            }
        }
    }

    func copyInviteLink() {
        run { [self] in
            let created = try await accountFlow.createTeamInviteLink(expiresInDays: 7, maxUses: nil)
            lastInviteLinkURL = created.url
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(created.url, forType: .string)
            notice = String(localized: "teamMembers.link.copied", defaultValue: "Invite link copied. It expires in 7 days.")
        }
    }

    func revoke(_ invitation: CloudTeamInvitation) {
        run { [self] in
            try await accountFlow.revokeTeamInvitation(invitationID: invitation.id)
            notice = nil
        }
    }

    func revoke(_ link: CloudTeamInviteLink) {
        run { [self] in
            try await accountFlow.revokeTeamInviteLink(linkID: link.id)
            if lastInviteLinkURL != nil { lastInviteLinkURL = nil }
        }
    }

    func remove(_ member: CloudTeamMember) {
        run { [self] in
            try await accountFlow.removeTeamMember(userID: member.userId)
        }
    }

    func setRole(_ role: CloudTeamRole, for member: CloudTeamMember) {
        guard role != member.role else { return }
        run { [self] in
            _ = try await accountFlow.changeTeamMemberRole(userID: member.userId, role: role)
        }
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
                errorMessage = HostAccountFlow.teamMembersUserMessage(error)
            }
        }
    }
}

struct CloudTeamMembersView: View {
    @Bindable var model: CloudTeamMembersModel
    @FocusState private var inviteFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.detail?.canInvite ?? false {
                inviteSection
            }
            messages
            List {
                membersSection
                if let detail = model.detail, detail.canInvite {
                    if !detail.invitations.isEmpty { invitationsSection(detail.invitations) }
                    if !detail.links.isEmpty { linksSection(detail.links) }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("CloudTeamMembersList")
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 360)
        .disabled(model.isSubmitting)
        .onAppear { if model.detail == nil { model.reload() } }
        .onChange(of: model.focusInviteRequest, initial: true) { _, value in
            if value > 0 { inviteFieldFocused = true }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.teamName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let seats = model.seatSummary {
                    Text(seats)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudTeamMembersSeatSummary")
                }
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "teamMembers.refresh", defaultValue: "Refresh members"))
            }
        }
    }

    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "teamMembers.invite.placeholder", defaultValue: "Email addresses, comma separated"),
                    text: $model.inviteEmails
                )
                .textFieldStyle(.roundedBorder)
                .focused($inviteFieldFocused)
                .onSubmit { model.submitInvite() }
                .accessibilityIdentifier("CloudTeamMembersInviteField")
                Picker("", selection: $model.inviteRole) {
                    Text(String(localized: "teamMembers.role.member", defaultValue: "Member")).tag(CloudTeamRole.member)
                    Text(String(localized: "teamMembers.role.admin", defaultValue: "Admin")).tag(CloudTeamRole.admin)
                }
                .labelsHidden()
                .frame(width: 96)
                .accessibilityLabel(String(localized: "teamMembers.invite.roleLabel", defaultValue: "Invite role"))
                Button(String(localized: "teamMembers.invite.send", defaultValue: "Invite")) {
                    model.submitInvite()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.inviteEmails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("CloudTeamMembersInviteButton")
            }
            HStack(spacing: 8) {
                Button {
                    model.copyInviteLink()
                } label: {
                    Label(
                        String(localized: "teamMembers.link.copy", defaultValue: "Copy invite link"),
                        systemImage: "link"
                    )
                }
                .accessibilityIdentifier("CloudTeamMembersCopyLinkButton")
                if let url = model.lastInviteLinkURL {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudTeamMembersError")
        } else if let notice = model.notice {
            Text(notice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudTeamMembersNotice")
        }
    }

    private var membersSection: some View {
        Section(String(localized: "teamMembers.section.members", defaultValue: "Members")) {
            if let detail = model.detail {
                ForEach(detail.members) { member in
                    memberRow(member, detail: detail)
                }
            } else if !model.isLoading, model.errorMessage == nil {
                Text(String(localized: "sidebar.account.loadingTeams", defaultValue: "Loading teams…"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func memberRow(_ member: CloudTeamMember, detail: CloudTeamDetail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: member.role == .admin ? "person.badge.key" : "person")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(member.label).lineLimit(1)
                    if member.isViewer {
                        Text(String(localized: "teamMembers.you", defaultValue: "you"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let email = member.email, email != member.label {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if detail.canInvite, !member.isViewer {
                Picker("", selection: Binding(
                    get: { member.role },
                    set: { model.setRole($0, for: member) }
                )) {
                    Text(String(localized: "teamMembers.role.member", defaultValue: "Member")).tag(CloudTeamRole.member)
                    Text(String(localized: "teamMembers.role.admin", defaultValue: "Admin")).tag(CloudTeamRole.admin)
                }
                .labelsHidden()
                .frame(width: 96)
                .accessibilityLabel(String(localized: "teamMembers.invite.roleLabel", defaultValue: "Invite role"))
            } else {
                Text(member.role == .admin
                    ? String(localized: "teamMembers.role.admin", defaultValue: "Admin")
                    : String(localized: "teamMembers.role.member", defaultValue: "Member"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if member.isViewer {
                if detail.members.count > 1 {
                    Button(String(localized: "teamMembers.leave", defaultValue: "Leave")) {
                        model.remove(member)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            } else if detail.viewer.permissions.removeMembers {
                Button {
                    model.remove(member)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .accessibilityLabel(String(
                    format: String(localized: "teamMembers.remove", defaultValue: "Remove %@"),
                    member.label
                ))
            }
        }
        .accessibilityIdentifier("CloudTeamMember_\(member.userId)")
    }

    private func invitationsSection(_ invitations: [CloudTeamInvitation]) -> some View {
        Section(String(localized: "teamMembers.section.invitations", defaultValue: "Pending invitations")) {
            ForEach(invitations) { invitation in
                HStack(spacing: 10) {
                    Image(systemName: "envelope").foregroundStyle(.secondary).frame(width: 18)
                    Text(invitation.email ?? invitation.id).lineLimit(1)
                    Spacer()
                    Text(invitation.role == .admin
                        ? String(localized: "teamMembers.role.admin", defaultValue: "Admin")
                        : String(localized: "teamMembers.role.member", defaultValue: "Member"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button(String(localized: "teamMembers.invitation.revoke", defaultValue: "Revoke")) {
                        model.revoke(invitation)
                    }
                    .buttonStyle(.borderless)
                }
                .accessibilityIdentifier("CloudTeamInvitation_\(invitation.id)")
            }
        }
    }

    private func linksSection(_ links: [CloudTeamInviteLink]) -> some View {
        Section(String(localized: "teamMembers.section.links", defaultValue: "Invite links")) {
            ForEach(links) { link in
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(.secondary).frame(width: 18)
                    Text(linkSummary(link)).lineLimit(1)
                    Spacer()
                    Button(String(localized: "teamMembers.invitation.revoke", defaultValue: "Revoke")) {
                        model.revoke(link)
                    }
                    .buttonStyle(.borderless)
                }
                .accessibilityIdentifier("CloudTeamInviteLink_\(link.id)")
            }
        }
    }

    private func linkSummary(_ link: CloudTeamInviteLink) -> String {
        let uses: String
        if let maxUses = link.maxUses {
            uses = String(
                format: String(localized: "teamMembers.link.usesOf", defaultValue: "%1$d of %2$d uses"),
                link.useCount,
                maxUses
            )
        } else {
            uses = String(
                format: String(localized: "teamMembers.link.uses", defaultValue: "%d uses"),
                link.useCount
            )
        }
        guard let expiresAt = link.expiresAt else { return uses }
        let expiry = expiresAt.formatted(date: .abbreviated, time: .omitted)
        return String(
            format: String(localized: "teamMembers.link.summary", defaultValue: "%1$@ · expires %2$@"),
            uses,
            expiry
        )
    }
}
