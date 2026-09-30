import AppKit
import CmuxCloud
import Observation
import SwiftUI

/// View state for the Invite popover. Every action goes through
/// ``HostAccountFlow``, the same path as Settings, the socket and the CLI.
@MainActor
@Observable
final class CloudTeamInviteModel {
    enum Stage: Equatable {
        case composing
        case sent(count: Int)
    }

    private let accountFlow: HostAccountFlow
    var onFinished: (() -> Void)?
    var stage: Stage = .composing
    var emails = ""
    var sentEmails: [String] = []
    var role: CloudTeamRole = .member
    var isSubmitting = false
    var isLoading = false
    var errorMessage: String?
    var notice: String?
    var detail: CloudTeamDetail?
    var copiedLinkURL: String?

    init(accountFlow: HostAccountFlow) {
        self.accountFlow = accountFlow
    }

    var teamName: String {
        detail?.team.displayName
            ?? accountFlow.activeTeamDisplayName
            ?? String(localized: "sidebar.account.noTeam", defaultValue: "No team")
    }

    var canInvite: Bool { detail?.canInvite ?? true }


    /// Seats still open under a Pro or Max cap; nil when uncapped.
    var openSeats: Int? { detail?.openSeats }

    var seatLimit: Int? { detail?.billing.memberLimit }

    var parsedEmails: [String] {
        var seen = Set<String>()
        return Self.splitEmails(emails).filter { seen.insert($0.lowercased()).inserted }
    }

    var canSend: Bool {
        !parsedEmails.isEmpty && canInvite && openSeats != 0
    }

    static func splitEmails(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func load() {
        isLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isLoading = false }
            do {
                detail = try await accountFlow.cloudTeamDetail()
            } catch {
                errorMessage = HostAccountFlow.teamMembersUserMessage(error)
            }
        }
    }

    func send() {
        let emails = parsedEmails
        guard canSend, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        notice = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSubmitting = false }
            do {
                let result = try await accountFlow.cloudInviteTeamMembers(emails: emails, role: role)
                if result.failed.isEmpty {
                    sentEmails = emails
                    self.emails = ""
                    stage = .sent(count: result.invitations.count)
                } else {
                    let failed = Set(result.failed.map { $0.email.lowercased() })
                    sentEmails = emails.filter { !failed.contains($0.lowercased()) }
                    self.emails = emails.filter { failed.contains($0.lowercased()) }.joined(separator: ", ")
                    errorMessage = String(
                        format: String(localized: "cloudInvite.partial", defaultValue: "Could not invite: %@"),
                        result.failed.map(\.email).joined(separator: ", ")
                    )
                    if !result.invitations.isEmpty {
                        notice = String(localized: "cloudInvite.someSent", defaultValue: "The other invitations were sent.")
                    }
                }
            } catch {
                errorMessage = HostAccountFlow.teamMembersUserMessage(error)
            }
        }
    }

    func copyLink() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSubmitting = false }
            do {
                let created = try await accountFlow.cloudCreateTeamInviteLink(expiresInDays: 7, maxUses: nil)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(created.url, forType: .string)
                copiedLinkURL = created.url
                notice = String(localized: "cloudInvite.linkCopied", defaultValue: "Invite link copied. Anyone with it joins as a member for 7 days.")
            } catch {
                errorMessage = HostAccountFlow.teamMembersUserMessage(error)
            }
        }
    }

    func openMembers() {
        onFinished?()
        accountFlow.showTeamMembers(focusInvite: false)
    }

    /// One short status line under the field: loading, seats, error or notice.
    var statusLine: (text: String, isError: Bool)? {
        if let error = errorMessage { return (error, true) }
        if let notice { return (notice, false) }
        if !canInvite {
            return (String(localized: "cloudInvite.notAdmin.short", defaultValue: "Only team admins can invite."), false)
        }
        if let limit = seatLimit, let open = openSeats {
            if open == 0 {
                return (String(localized: "cloudInvite.seatsFull.short", defaultValue: "No seats left on this plan. Upgrade to Team to invite more."), true)
            }
            return (String(format: String(localized: "cloudInvite.seatsOpen", defaultValue: "%1$d of %2$d seats open on this plan."), open, limit), false)
        }
        return nil
    }

    func finish() {
        onFinished?()
    }
}

/// The Invite popover on the Cloud header. Short on purpose: one sentence
/// about what sharing means, the addresses, a role, Send.
struct CloudTeamInvitePopover: View {
    let accountFlow: HostAccountFlow
    let presentation: CloudTeamPickerPresentation
    @State private var model: CloudTeamInviteModel
    @FocusState private var emailFieldFocused: Bool

    init(accountFlow: HostAccountFlow, presentation: CloudTeamPickerPresentation) {
        self.accountFlow = accountFlow
        self.presentation = presentation
        _model = State(initialValue: CloudTeamInviteModel(accountFlow: accountFlow))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.stage {
            case .composing:
                composing
            case .sent:
                sent
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            model.onFinished = { presentation.isInvitePresented = false }
            model.load()
            emailFieldFocused = true
        }
        .accessibilityIdentifier("CloudTeamInvitePopover")
    }

    private var composing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                format: String(localized: "cloudInvite.heading.short", defaultValue: "Invite to %@"),
                model.teamName
            ))
            .font(.headline)
            .lineLimit(1)
            Text(String(localized: "cloudInvite.oneLiner", defaultValue: "Members share this team's Cloud machines. Your Mac stays private."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(
                String(localized: "cloudInvite.emails.placeholder.short", defaultValue: "Email, comma separated"),
                text: $model.emails
            )
            .textFieldStyle(.roundedBorder)
            .focused($emailFieldFocused)
            .onSubmit { model.send() }
            .disabled(!model.canInvite || model.isSubmitting)
            .accessibilityIdentifier("CloudTeamInviteEmails")
            HStack(spacing: 8) {
                Picker("", selection: $model.role) {
                    Text(String(localized: "cloudInvite.role.member", defaultValue: "Member")).tag(CloudTeamRole.member)
                    Text(String(localized: "cloudInvite.role.admin", defaultValue: "Admin")).tag(CloudTeamRole.admin)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(String(localized: "cloudInvite.role.label", defaultValue: "Join as"))
                Spacer(minLength: 0)
                Button {
                    model.send()
                } label: {
                    if model.isSubmitting {
                        ProgressView().controlSize(.small).frame(minWidth: 70)
                    } else {
                        Text(String(localized: "cloudInvite.send", defaultValue: "Send Invite")).frame(minWidth: 70)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend || model.isSubmitting)
                .accessibilityIdentifier("CloudTeamInviteSend")
            }
            if let status = model.statusLine {
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(status.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(status.isError ? "CloudTeamInviteError" : "CloudTeamInviteStatus")
            }
            HStack(spacing: 12) {
                Button(String(localized: "cloudInvite.copyLink.short", defaultValue: "Copy link")) {
                    model.copyLink()
                }
                .buttonStyle(.link)
                .fixedSize()
                .disabled(!model.canInvite || model.isSubmitting)
                .accessibilityIdentifier("CloudTeamInviteCopyLink")
                Button(String(localized: "cloudInvite.manageMembers", defaultValue: "Manage members…")) {
                    model.openMembers()
                }
                .buttonStyle(.link)
                .fixedSize()
            }
            .font(.callout)
        }
    }

    private var sent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                format: String(localized: "cloudInvite.sentTo", defaultValue: "Sent to %@"),
                model.sentEmails.joined(separator: ", ")
            ))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(String(localized: "cloudInvite.inviteMore", defaultValue: "Invite More")) {
                    model.stage = .composing
                }
                .buttonStyle(.link)
                .fixedSize()
                Spacer()
                Button(String(localized: "cloudInvite.done", defaultValue: "Done")) {
                    model.finish()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("CloudTeamInviteDone")
            }
        }
        .accessibilityIdentifier("CloudTeamInviteSent")
    }
}
