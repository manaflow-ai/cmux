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
    static let sheetSize = NSSize(width: 480, height: 330)

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
        // A fixed-size window with an NSHostingView, not a hosting controller
        // sized by preferred content size: that path let SwiftUI hand AppKit
        // an unbounded constraint while the sheet animated open, which threw.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.sheetSize.width, height: Self.sheetSize.height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "cloudInvite.title", defaultValue: "Invite People")
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: CloudTeamInviteSheet(model: model))
        hostingView.frame = NSRect(origin: .zero, size: Self.sheetSize)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
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

    func finish() {
        onFinished?()
    }
}

struct CloudTeamInviteSheet: View {
    @Bindable var model: CloudTeamInviteModel
    @FocusState private var emailFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.stage {
            case .composing:
                composing
            case let .sent(count):
                sentState(count: count)
            }
        }
        .padding(20)
        .frame(width: CloudTeamInviteSheetPresenter.sheetSize.width, height: CloudTeamInviteSheetPresenter.sheetSize.height, alignment: .top)
        .disabled(model.isSubmitting)
        .onAppear { emailFieldFocused = true }
        .accessibilityIdentifier("CloudTeamInviteSheet")
    }

    private var composing: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    format: String(localized: "cloudInvite.heading", defaultValue: "Invite people to %@"),
                    model.teamName
                ))
                .font(.headline)
                .lineLimit(1)
                Text(String(localized: "cloudInvite.subtitle", defaultValue: "Members get the team's Cloud machines. Nothing on your Mac is shared."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "cloudInvite.point.cloud", defaultValue: "Cloud machines are shared by default. Members can open, attach to and create them."))
                Text(String(localized: "cloudInvite.point.local", defaultValue: "Your Mac stays private. Local terminals, files and paired devices are never shared."))
                Text(String(localized: "cloudInvite.point.admin", defaultValue: "Admins invite and remove people, change roles and manage billing."))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("CloudTeamInviteExplainer")
            TextField(
                String(localized: "cloudInvite.emails.placeholder", defaultValue: "name@company.com, another@company.com"),
                text: $model.emails
            )
            .textFieldStyle(.roundedBorder)
            .focused($emailFieldFocused)
            .onSubmit { model.send() }
            .disabled(!model.canInvite)
            .accessibilityIdentifier("CloudTeamInviteEmails")
            HStack(spacing: 8) {
                Text(String(localized: "cloudInvite.role.label", defaultValue: "Join as"))
                    .font(.callout)
                Picker("", selection: $model.role) {
                    Text(String(localized: "cloudInvite.role.member", defaultValue: "Member")).tag(CloudTeamRole.member)
                    Text(String(localized: "cloudInvite.role.admin", defaultValue: "Admin")).tag(CloudTeamRole.admin)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(String(localized: "cloudInvite.role.label", defaultValue: "Join as"))
                Spacer(minLength: 0)
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            if let limit = model.seatLimit, let open = model.openSeats {
                Text(seatLine(open: open, limit: limit))
                    .font(.callout)
                    .foregroundStyle(open == 0 ? .red : .secondary)
                    .accessibilityIdentifier("CloudTeamInviteSeats")
            }
            messages
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button(String(localized: "cloudInvite.copyLink", defaultValue: "Copy invite link")) {
                    model.copyLink()
                }
                .disabled(!model.canInvite)
                .accessibilityIdentifier("CloudTeamInviteCopyLink")
                Button(String(localized: "cloudInvite.manageMembers", defaultValue: "Manage members…")) {
                    model.openMembers()
                }
                .buttonStyle(.link)
                .fixedSize()
                Spacer()
                Button(String(localized: "cloudInvite.cancel", defaultValue: "Cancel")) {
                    model.finish()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "cloudInvite.send", defaultValue: "Send Invite")) {
                    model.send()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
                .accessibilityIdentifier("CloudTeamInviteSend")
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

    @ViewBuilder
    private var messages: some View {
        if !model.canInvite {
            Text(String(localized: "cloudInvite.notAdmin", defaultValue: "Only team admins can invite people. Ask an admin, or switch to a team you manage."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = model.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudTeamInviteError")
        } else if let notice = model.notice {
            Text(notice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("CloudTeamInviteNotice")
        }
    }

    private func sentState(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sentTitle(count: count)).font(.headline)
            if !model.sentEmails.isEmpty {
                Text(model.sentEmails.joined(separator: ", "))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(String(localized: "cloudInvite.sent.body", defaultValue: "Each person gets an email from cmux with a link to join. They appear in the team as soon as they accept. Pending invitations are listed in Settings › Account."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button(String(localized: "cloudInvite.inviteMore", defaultValue: "Invite More")) {
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
