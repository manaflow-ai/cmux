import AppKit
import CmuxCloud
import Observation
import SwiftUI

/// The one path every "Invite" entrypoint goes through: the Cloud header
/// button, the team picker row, the command palette and the socket. A sheet
/// on the main window that explains what a member gets before the first
/// invite is sent, then sends email invitations or copies a link.
@MainActor
final class CloudTeamInviteSheetPresenter {
    static let shared = CloudTeamInviteSheetPresenter()

    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?
    private var model: CloudTeamInviteModel?

    private var isPresenting: Bool { sheetWindow != nil }

    /// Presents the invite sheet for the confirmed active team. A second
    /// request while one is up re-raises the host window.
    func present(accountFlow: HostAccountFlow, preferredWindow: NSWindow?) {
        if isPresenting {
            (hostWindow ?? sheetWindow)?.makeKeyAndOrderFront(nil)
            return
        }
        let model = CloudTeamInviteModel(accountFlow: accountFlow)
        model.onFinished = { [weak self] in self?.dismiss() }
        let controller = NSHostingController(rootView: CloudTeamInviteSheet(model: model))
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = String(localized: "cloudInvite.title", defaultValue: "Invite People")
        window.isReleasedWhenClosed = false
        self.model = model
        sheetWindow = window
        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            host.beginSheet(window) { _ in }
        } else {
            hostWindow = nil
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
        model.load()
    }

    private func dismiss() {
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetWindow = nil
        hostWindow = nil
        model = nil
    }
}

/// View state for the invite sheet. Every action goes through
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
        emails
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
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
        guard !emails.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        notice = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSubmitting = false }
            do {
                let result = try await accountFlow.cloudInviteTeamMembers(emails: emails, role: role)
                if result.failed.isEmpty {
                    stage = .sent(count: result.invitations.count)
                } else {
                    self.emails = result.failed.map(\.email).joined(separator: ", ")
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

    func finish() {
        onFinished?()
    }
}

struct CloudTeamInviteSheet: View {
    @Bindable var model: CloudTeamInviteModel
    @FocusState private var emailFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.stage {
            case .composing:
                sharingExplainer
                composer
                messages
                composingButtons
            case let .sent(count):
                sentState(count: count)
            }
        }
        .padding(24)
        .frame(width: 520)
        .disabled(model.isSubmitting)
        .onAppear { emailFieldFocused = true }
        .accessibilityIdentifier("CloudTeamInviteSheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(
                format: String(localized: "cloudInvite.heading", defaultValue: "Invite people to %@"),
                model.teamName
            ))
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            if let limit = model.seatLimit, let open = model.openSeats {
                Text(seatLine(open: open, limit: limit))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CloudTeamInviteSeats")
            } else {
                Text(String(localized: "cloudInvite.subtitle", defaultValue: "Members get the team's Cloud machines. Nothing on your Mac is shared."))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func seatLine(open: Int, limit: Int) -> String {
        if open == 0 {
            return String(
                format: String(localized: "cloudInvite.seatsFull", defaultValue: "All %d seats on this plan are used. Remove someone or upgrade to Team to invite more."),
                limit
            )
        }
        return String(
            format: String(localized: "cloudInvite.seatsOpen", defaultValue: "%1$d of %2$d seats open on this plan."),
            open,
            limit
        )
    }

    /// What joining means, before the first invite goes out.
    private var sharingExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            explainerRow(
                symbol: "cloud.fill",
                title: String(localized: "cloudInvite.explain.cloud.title", defaultValue: "Cloud machines are shared by default"),
                body: String(localized: "cloudInvite.explain.cloud.body", defaultValue: "Every member can open, attach to and create machines in this team. Machines and their files live in the cloud, on the team's plan.")
            )
            explainerRow(
                symbol: "lock.fill",
                title: String(localized: "cloudInvite.explain.local.title", defaultValue: "Your Mac stays private"),
                body: String(localized: "cloudInvite.explain.local.body", defaultValue: "Local terminals, workspaces, files and paired devices are never shared with the team.")
            )
            explainerRow(
                symbol: "person.badge.key.fill",
                title: String(localized: "cloudInvite.explain.admin.title", defaultValue: "Admins manage the team"),
                body: String(localized: "cloudInvite.explain.admin.body", defaultValue: "Admins can invite and remove people, change roles and manage billing. Members cannot.")
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .accessibilityIdentifier("CloudTeamInviteExplainer")
    }

    private func explainerRow(symbol: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).cmuxFont(size: 12, weight: .medium)
                Text(body).cmuxFont(size: 11).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "cloudInvite.emails.label", defaultValue: "Email addresses"))
                .cmuxFont(size: 12, weight: .medium)
            TextField(
                String(localized: "cloudInvite.emails.placeholder", defaultValue: "name@company.com, another@company.com"),
                text: $model.emails,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .focused($emailFieldFocused)
            .onSubmit { model.send() }
            .disabled(!model.canInvite)
            .accessibilityIdentifier("CloudTeamInviteEmails")
            HStack(spacing: 10) {
                Text(String(localized: "cloudInvite.role.label", defaultValue: "Join as"))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.role) {
                    Text(String(localized: "cloudInvite.role.member", defaultValue: "Member")).tag(CloudTeamRole.member)
                    Text(String(localized: "cloudInvite.role.admin", defaultValue: "Admin")).tag(CloudTeamRole.admin)
                }
                .labelsHidden()
                .frame(width: 110)
                .accessibilityLabel(String(localized: "cloudInvite.role.label", defaultValue: "Join as"))
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if !model.canInvite {
            Text(String(localized: "cloudInvite.notAdmin", defaultValue: "Only team admins can invite people. Ask an admin, or switch to a team you manage."))
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.errorMessage {
            Text(error)
                .cmuxFont(size: 11)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudTeamInviteError")
        } else if let notice = model.notice {
            Text(notice)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudTeamInviteNotice")
        }
    }

    private var composingButtons: some View {
        HStack(spacing: 10) {
            Button {
                model.copyLink()
            } label: {
                Label(String(localized: "cloudInvite.copyLink", defaultValue: "Copy invite link"), systemImage: "link")
            }
            .disabled(!model.canInvite)
            .accessibilityIdentifier("CloudTeamInviteCopyLink")
            Button(String(localized: "cloudInvite.manageMembers", defaultValue: "Manage members…")) {
                model.openMembers()
            }
            .buttonStyle(.link)
            .controlSize(.small)
            Spacer()
            Button(String(localized: "cloudInvite.cancel", defaultValue: "Cancel")) {
                model.finish()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "cloudInvite.send", defaultValue: "Send Invites")) {
                model.send()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.parsedEmails.isEmpty || !model.canInvite || model.openSeats == 0)
            .accessibilityIdentifier("CloudTeamInviteSend")
        }
    }

    private func sentState(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sentTitle(count: count)).cmuxFont(size: 13, weight: .medium)
                    Text(String(localized: "cloudInvite.sent.body", defaultValue: "Each person gets an email from cmux with a link to join. They appear in the team as soon as they accept. Pending invitations are listed in Settings › Account."))
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(String(localized: "cloudInvite.inviteMore", defaultValue: "Invite More")) {
                    model.emails = ""
                    model.stage = .composing
                }
                Spacer()
                Button(String(localized: "cloudInvite.done", defaultValue: "Done")) {
                    model.finish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("CloudTeamInviteDone")
            }
        }
        .accessibilityIdentifier("CloudTeamInviteSent")
    }

    private func sentTitle(count: Int) -> String {
        count == 1
            ? String(localized: "cloudInvite.sent.one", defaultValue: "Invitation sent")
            : String(localized: "cloudInvite.sent.many", defaultValue: "Invitations sent")
    }
}
