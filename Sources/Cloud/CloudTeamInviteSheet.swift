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
    static let sheetSize = NSSize(width: 560, height: 600)

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
    /// Committed recipients shown as chips.
    var recipients: [String] = []
    /// Text still being typed in the field.
    var draft = ""
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

    /// Up to two initials from the team name, for the avatar badge.
    var teamInitials: String {
        let words = teamName.split(separator: " ").prefix(2)
        let initials = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return initials.isEmpty ? "T" : initials
    }

    /// Seats still open under a Pro or Max cap; nil when uncapped.
    var openSeats: Int? { detail?.openSeats }

    var seatLimit: Int? { detail?.billing.memberLimit }

    /// Recipients plus whatever is still in the field.
    var parsedEmails: [String] {
        var seen = Set<String>()
        return (recipients + Self.splitEmails(draft)).filter { seen.insert($0.lowercased()).inserted }
    }

    var invalidRecipients: Set<String> {
        Set(parsedEmails.filter { !Self.looksLikeEmail($0) })
    }

    var canSend: Bool {
        !parsedEmails.isEmpty && invalidRecipients.isEmpty && canInvite && openSeats != 0
    }

    static func splitEmails(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func looksLikeEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains(" ")
    }

    /// Moves the typed text into chips; called on comma, space, return and blur.
    func commitDraft() {
        let added = Self.splitEmails(draft)
        guard !added.isEmpty else { return }
        for email in added where !recipients.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
            recipients.append(email)
        }
        draft = ""
    }

    func remove(recipient: String) {
        recipients.removeAll { $0 == recipient }
    }

    var roleMeaning: String {
        role == .admin
            ? String(localized: "cloudInvite.role.admin.meaning", defaultValue: "Can invite and remove people, change roles and manage billing.")
            : String(localized: "cloudInvite.role.member.meaning", defaultValue: "Can open, attach to and create the team's Cloud machines.")
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
        commitDraft()
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
                    recipients = []
                    draft = ""
                    stage = .sent(count: result.invitations.count)
                } else {
                    let failed = Set(result.failed.map { $0.email.lowercased() })
                    sentEmails = emails.filter { !failed.contains($0.lowercased()) }
                    recipients = emails.filter { failed.contains($0.lowercased()) }
                    draft = ""
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

    private var accent: Color { Color.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            Divider()
            Group {
                switch model.stage {
                case .composing:
                    composing
                case let .sent(count):
                    sentState(count: count)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(width: CloudTeamInviteSheetPresenter.sheetSize.width, height: CloudTeamInviteSheetPresenter.sheetSize.height, alignment: .top)
        .disabled(model.isSubmitting)
        .onAppear { emailFieldFocused = true }
        .accessibilityIdentifier("CloudTeamInviteSheet")
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.opacity(0.18))
                Text(model.teamInitials)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(
                    format: String(localized: "cloudInvite.heading", defaultValue: "Invite people to %@"),
                    model.teamName
                ))
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                Text(String(localized: "cloudInvite.subtitle", defaultValue: "Members get the team's Cloud machines. Nothing on your Mac is shared."))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.06))
    }

    // MARK: Composing

    private var composing: some View {
        VStack(alignment: .leading, spacing: 18) {
            sharingCards
            recipientsSection
            roleSection
            if let limit = model.seatLimit, let open = model.openSeats {
                seatMeter(open: open, limit: limit)
            }
            messages
            Spacer(minLength: 0)
            composingButtons
        }
    }

    /// Three cards that say what joining means, before the first invite.
    private var sharingCards: some View {
        HStack(spacing: 10) {
            sharingCard(
                symbol: "cloud.fill",
                tint: accent,
                title: String(localized: "cloudInvite.card.cloud.title", defaultValue: "Cloud machines"),
                body: String(localized: "cloudInvite.card.cloud.body", defaultValue: "Shared by default. Members open, attach to and create them on the team's plan.")
            )
            sharingCard(
                symbol: "lock.fill",
                tint: .green,
                title: String(localized: "cloudInvite.card.local.title", defaultValue: "Your Mac"),
                body: String(localized: "cloudInvite.card.local.body", defaultValue: "Stays private. Local terminals, files and paired devices are never shared.")
            )
            sharingCard(
                symbol: "person.badge.key.fill",
                tint: .orange,
                title: String(localized: "cloudInvite.card.admin.title", defaultValue: "Admins"),
                body: String(localized: "cloudInvite.card.admin.body", defaultValue: "Invite and remove people, change roles and manage billing.")
            )
        }
        .accessibilityIdentifier("CloudTeamInviteExplainer")
    }

    private func sharingCard(symbol: String, tint: Color, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            Text(title).cmuxFont(size: 12, weight: .semibold)
            Text(body)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }

    private var recipientsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "cloudInvite.emails.label", defaultValue: "Email addresses"))
                    .cmuxFont(size: 12, weight: .medium)
                Spacer()
                if !model.parsedEmails.isEmpty {
                    Text(recipientCount)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if !model.recipients.isEmpty {
                    ChipFlow(spacing: 6) {
                        ForEach(model.recipients, id: \.self) { email in
                            recipientChip(email)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(
                        model.recipients.isEmpty
                            ? String(localized: "cloudInvite.emails.placeholder", defaultValue: "name@company.com, another@company.com")
                            : String(localized: "cloudInvite.emails.more", defaultValue: "Add another…"),
                        text: $model.draft
                    )
                    .textFieldStyle(.plain)
                    .focused($emailFieldFocused)
                    .onSubmit { model.send() }
                    .onChange(of: model.draft) { _, value in
                        if value.last == "," || value.last == " " || value.last == ";" { model.commitDraft() }
                    }
                    .onChange(of: emailFieldFocused) { _, focused in
                        if !focused { model.commitDraft() }
                    }
                    .disabled(!model.canInvite)
                    .accessibilityIdentifier("CloudTeamInviteEmails")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(emailFieldFocused ? accent.opacity(0.7) : Color.primary.opacity(0.12), lineWidth: emailFieldFocused ? 1.5 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { emailFieldFocused = true }
            if !model.invalidRecipients.isEmpty {
                Text(String(localized: "cloudInvite.emails.invalid", defaultValue: "Fix the highlighted addresses before sending."))
                    .cmuxFont(size: 11)
                    .foregroundStyle(.red)
            }
        }
    }

    private var recipientCount: String {
        let count = model.parsedEmails.count
        return count == 1
            ? String(localized: "cloudInvite.recipients.one", defaultValue: "1 person")
            : String(format: String(localized: "cloudInvite.recipients.many", defaultValue: "%d people"), count)
    }

    private func recipientChip(_ email: String) -> some View {
        let invalid = model.invalidRecipients.contains(email)
        return HStack(spacing: 4) {
            Text(email).cmuxFont(size: 11).lineLimit(1)
            Button {
                model.remove(recipient: email)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(
                format: String(localized: "cloudInvite.recipient.remove", defaultValue: "Remove %@"),
                email
            ))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(invalid ? Color.red.opacity(0.14) : accent.opacity(0.14)))
        .overlay(Capsule().strokeBorder(invalid ? Color.red.opacity(0.6) : Color.clear))
        .foregroundStyle(invalid ? Color.red : Color.primary)
    }

    private var roleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(String(localized: "cloudInvite.role.label", defaultValue: "Join as"))
                    .cmuxFont(size: 12, weight: .medium)
                Picker("", selection: $model.role) {
                    Text(String(localized: "cloudInvite.role.member", defaultValue: "Member")).tag(CloudTeamRole.member)
                    Text(String(localized: "cloudInvite.role.admin", defaultValue: "Admin")).tag(CloudTeamRole.admin)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .accessibilityLabel(String(localized: "cloudInvite.role.label", defaultValue: "Join as"))
                Spacer(minLength: 0)
            }
            Text(model.roleMeaning)
                .cmuxFont(size: 11)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seatMeter(open: Int, limit: Int) -> some View {
        let used = max(0, limit - open)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "cloudInvite.seats.label", defaultValue: "Seats on this plan"))
                    .cmuxFont(size: 12, weight: .medium)
                Spacer()
                Text(seatLine(open: open, limit: limit))
                    .cmuxFont(size: 11)
                    .foregroundStyle(open == 0 ? .red : .secondary)
                    .accessibilityIdentifier("CloudTeamInviteSeats")
            }
            ProgressView(value: Double(used), total: Double(max(limit, 1)))
                .tint(open == 0 ? .red : accent)
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
            statusLine(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                text: String(localized: "cloudInvite.notAdmin", defaultValue: "Only team admins can invite people. Ask an admin, or switch to a team you manage.")
            )
        }
        if let error = model.errorMessage {
            statusLine(symbol: "xmark.octagon.fill", tint: .red, text: error)
                .accessibilityIdentifier("CloudTeamInviteError")
        } else if let notice = model.notice {
            statusLine(symbol: "checkmark.circle.fill", tint: .green, text: notice)
                .accessibilityIdentifier("CloudTeamInviteNotice")
        }
    }

    private func statusLine(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).cmuxFont(size: 11).fixedSize(horizontal: false, vertical: true)
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
            .safeHelp(String(localized: "cloudInvite.copyLink.help", defaultValue: "Anyone with the link joins as a member. It expires in 7 days."))
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
            Button {
                model.send()
            } label: {
                Label(sendTitle, systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canSend)
            .accessibilityIdentifier("CloudTeamInviteSend")
        }
    }

    private var sendTitle: String {
        let count = model.parsedEmails.count
        return count > 1
            ? String(format: String(localized: "cloudInvite.send.count", defaultValue: "Send %d Invites"), count)
            : String(localized: "cloudInvite.send", defaultValue: "Send Invite")
    }

    // MARK: Sent

    private func sentState(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.16))
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(sentTitle(count: count)).font(.system(size: 15, weight: .semibold))
                    Text(String(localized: "cloudInvite.sent.body", defaultValue: "Each person gets an email from cmux with a link to join. They appear in the team as soon as they accept. Pending invitations are listed in Settings › Account."))
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.sentEmails.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(model.sentEmails, id: \.self) { email in
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
                            Text(email).cmuxFont(size: 11).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button(String(localized: "cloudInvite.inviteMore", defaultValue: "Invite More")) {
                    model.stage = .composing
                }
                Button(String(localized: "cloudInvite.manageMembers", defaultValue: "Manage members…")) {
                    model.openMembers()
                }
                .buttonStyle(.link)
                .controlSize(.small)
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

/// Wraps chips onto new lines. A Layout, so it stays inside the fixed sheet
/// size and never asks AppKit for an unbounded dimension.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
