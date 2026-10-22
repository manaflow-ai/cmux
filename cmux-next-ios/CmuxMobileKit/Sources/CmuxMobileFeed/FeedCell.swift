#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
import SwiftUI
import UIKit

/// SPEC 8.2 Feed cell: avatar column, header, quote bubble, status chip,
/// web-rendered markdown capped at 8 lines with Show more, inline answer UI,
/// inline reply composer, and the footer actions.
///
/// The cell is a value of its event: it compares equal while `item` and
/// `expanded` are unchanged, so a live change to one event re-renders that
/// cell only, never every cell on screen (`FeedRow`). Actions reach the store
/// through `context`, one shared object whose identity never changes.
struct FeedCell: View {
    let item: FeedItem
    let context: FeedRowContext
    let expanded: Bool
    @State private var contentHeight: CGFloat?
    @State private var replying = false
    @State private var replyText = ""
    /// A reply the phone could not send (no chat to send it to), or the chat the reply went to,
    /// whose refusal (the Mac's reason) shows under the reply instead of a silent "You replied".
    @State private var replyFailure: String?
    @State private var replyChat: AgentChatStore?
    @FocusState private var replyFocused: Bool
    @State private var copied = false
    #if DEBUG
    private let director = DemoDirector.shared
    #endif

    /// Show more caps the body at 8 lines of body text at the current text size.
    @ScaledMetric(relativeTo: .body) private var collapsedHeight: CGFloat = 224
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(item: FeedItem, context: FeedRowContext, expanded: Bool) {
        self.item = item
        self.context = context
        self.expanded = expanded
        let plain = FeedPlainText(item.markdown)
        inlineText = plain.isInline ? plain.attributed : nil
        // Native rows never overflow; only web rows need the measured height.
        _contentHeight = State(initialValue: inlineText == nil
            ? WebMarkdownRenderer.shared.cachedHeight(markdown: item.markdown, style: .body) : 0)
    }

    /// Short inline text drawn natively instead of in a web view (D10); nil: the web view.
    private let inlineText: AttributedString?

    private var store: FeedStore { context.store }
    private func open() { context.open(item) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentAvatar(harness: item.harness, size: 40)
                .overlay(alignment: .topTrailing) {
                    if !item.isRead {
                        Circle().fill(Color.primary).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.cmuxMobileBackground, lineWidth: 2))
                            .offset(x: 2, y: -2)
                            .accessibilityLabel("Unread")
                    }
                }
            VStack(alignment: .leading, spacing: 8) {
                // Only the header, the quote and the body open the tab; the answer card,
                // its padding and the gaps never navigate (a mis-tap must not leave the Feed
                // mid-answer).
                header
                    .contentShape(.rect)
                    .onTapGesture(perform: open)
                if let quote = item.quote {
                    QuoteBubble(quote: quote)
                        .padding(.bottom, -4)
                        .contentShape(.rect)
                        .onTapGesture(perform: open)
                }
                statusChip
                bodyView
                inlineAnswer
                if let error = item.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    // The answer was refused (an unpaired phone, or Face ID cancelled): offer the decline.
                    if case .question(let question) = item.kind, question.isPending {
                        Button("Decline", role: .destructive) {
                            withAnimation(.cmuxMobileSmooth) { store.decline(item.id) }
                        }
                        .buttonStyle(.bordered)
                        .transition(.opacity)
                    }
                }
                if !item.replies.isEmpty {
                    replies
                }
                if item.opensTerminal, let pending = item.pending {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(pending)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("feed.reply.sending")
                    .transition(.opacity)
                }
                if let failure = replyFailure ?? replyChat?.clientError {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("feed.reply.failure")
                }
                if replying {
                    replyComposer
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contextMenu { menuItems }
        #if DEBUG
        .onChange(of: director.serial) { runDemoCommand() }
        #endif
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility sizes the source wraps under the name instead of truncating.
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.agentName).font(.subheadline.weight(.semibold))
                    TimelineView(.everyMinute) { timeline in
                        Text("\(item.workspaceTitle) · \(relativeTime(at: timeline.date))").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 4) {
                    Text(item.agentName).font(.subheadline.weight(.semibold)).lineLimit(1).layoutPriority(2)
                    Text("· \(item.workspaceTitle)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(0)
                    // The cell re-renders only when its event changes: the time keeps itself current.
                    TimelineView(.everyMinute) { timeline in
                        Text("· \(relativeTime(at: timeline.date))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    .layoutPriority(1)
                }
            }
            Spacer(minLength: 4)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .padding(.vertical, -12)
            .padding(.trailing, -10)
            .accessibilityLabel("Event actions")
        }
    }

    private func relativeTime(at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(item.createdAt))
        switch seconds {
        case ..<45: return "now"
        case ..<3600: return "\(max(1, seconds / 60))m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Section(item.createdAt.formatted(.dateTime.weekday(.wide).hour().minute())) {
            Button("Open Tab", systemImage: "arrow.up.right.square", action: open)
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.markdown }
            // Everything the trailing swipe leaves out lives here (SPEC swipe rules).
            if item.isRead {
                Button("Mark as Unread", systemImage: "envelope.badge") { store.markUnread(item.id) }
            } else {
                Button("Mark as Read", systemImage: "envelope.open") { store.markRead(item.id) }
            }
            Button("Done", systemImage: "checkmark") {
                withAnimation(.cmuxMobileSmooth) { store.markDone(item.id) }
            }
            Button("Mute This Workspace", systemImage: "bell.slash") {
                withAnimation(.cmuxMobileSmooth) { _ = store.mutedWorkspaces.insert(item.workspaceID) }
            }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch item.kind {
        case .permission where item.resolution == nil:
            chip(dot: .cmuxMobileWarning, symbol: nil, text: "Needs permission")
        case .question(let question) where question.isPending:
            chip(dot: nil, symbol: "questionmark.bubble", text: "Question")
        case .failed:
            chip(dot: .cmuxMobileDanger, symbol: nil, text: "Failed")
        case .needsInput where item.resolution == nil:
            chip(dot: .cmuxMobileWarning, symbol: nil, text: "Needs input")
        default:
            EmptyView()
        }
    }

    private func chip(dot: Color?, symbol: String?, text: String) -> some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let symbol { Image(systemName: symbol).font(.caption) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(minHeight: 24)
        .background(Color.cmuxMobileFill, in: .capsule)
    }

    private var isOverflowing: Bool { (contentHeight ?? 0) > collapsedHeight + 28 }

    private var bodyView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let inlineText {
                    Text(inlineText)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(.rect)
                        .onTapGesture(perform: open)
                } else {
                    WebMarkdownView(
                        markdown: item.markdown, style: .body,
                        collapsedHeight: collapsedHeight, isExpanded: expanded || !isOverflowing,
                        onTap: open
                    ) { height in
                        contentHeight = height
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if isOverflowing, !expanded {
                    LinearGradient(colors: [Color.cmuxMobileBackground.opacity(0), Color.cmuxMobileBackground], startPoint: .top, endPoint: .bottom)
                        .frame(height: 32)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            if isOverflowing {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.cmuxMobileSmooth) { context.setExpanded(item.id, !expanded) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(.rect)
                .padding(.vertical, -8)
                .contentTransition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var inlineAnswer: some View {
        switch item.kind {
        case .question(let question):
            QuestionCard(question: question, showsHeader: false) { answer in
                withAnimation(.cmuxMobileSmooth) { store.answer(item.id, answer: answer) }
            }
        case .needsInput:
            if let resolution = item.resolution {
                Label(resolution, systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                // A TUI prompt: the phone cannot answer it here.
                Button(action: open) {
                    Label("Answer in Terminal", systemImage: "terminal")
                }
                .buttonStyle(CmuxMobileCapsuleButtonStyle(.primary, size: .compact))
                .accessibilityIdentifier("feed.terminal.open")
            }
        case .permission(let request):
            if let resolution = item.resolution {
                Label(resolution, systemImage: resolution.hasPrefix("Denied") ? "xmark.circle" : "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if let pending = item.pending {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(pending)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("feed.permission.pending")
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let command = request.toolCall.command {
                        CodeCard(language: "bash", code: command, title: "Command", maxHeight: 120)
                    }
                    HStack(spacing: 8) {
                        ForEach(request.phoneOptions) { option in
                            Button {
                                withAnimation(.cmuxMobileSmooth) { store.respond(item.id, option: option) }
                            } label: {
                                // An allow is signed after Face ID (verify/phone-approvals.md).
                                if option.isAllow { Label(feedTitle(option), systemImage: "faceid") } else { Text(feedTitle(option)) }
                            }
                            .accessibilityHint(option.isAllow ? "Approve with Face ID" : "")
                            .buttonStyle(CmuxMobileCapsuleButtonStyle(option.kind == .allowOnce ? .primary : (option.isAllow ? .secondary : .destructive), size: .compact))
                        }
                    }
                }
                .transition(.opacity)
            }
        default:
            EmptyView()
        }
    }

    /// The Mac agent pane's words: "Allow once", "Deny".
    private func feedTitle(_ option: ACPPermissionOption) -> String {
        switch option.kind {
        case .allowOnce: "Allow once"
        case .allowAlways: "Allow for this chat"
        case .rejectOnce, .rejectAlways: "Deny"
        }
    }

    private var replies: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // A terminal agent's reply went into its terminal on the Mac.
            Text(item.opensTerminal ? "Sent to the terminal" : "You replied").font(.caption).foregroundStyle(.tertiary)
                .accessibilityIdentifier("feed.reply.sent")
            ForEach(Array(item.replies.enumerated()), id: \.offset) { _, reply in
                Text(reply)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.cmuxMobileBubble, in: .rect(cornerRadius: 16, style: .continuous))
                    .transition(.offset(y: 12).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var replyComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Reply to \(item.agentName)", text: $replyText, axis: .vertical)
                .lineLimit(1...5)
                .focused($replyFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            Button {
                sendReply()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(replyText.isEmpty ? Color(uiColor: .tertiaryLabel) : Color.cmuxMobileOnAccent)
                    .frame(width: 30, height: 30)
                    .background(replyText.isEmpty ? Color.cmuxMobileFill : Color.cmuxMobileAccent, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(5)
            .accessibilityLabel("Send reply")
        }
        .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 20, style: .continuous))
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyFailure = nil
        if item.opensTerminal {
            sendTerminalReply(text)
            return
        }
        let sent = FeedRouting.shared.sendPrompt?(item, text) ?? .failed("Open this chat to reply.")
        withAnimation(.cmuxMobileSnappy) {
            switch sent {
            case .sent(let chat):
                store.reply(item.id, text: text)
                replyChat = chat
            case .failed(let reason):
                replyFailure = reason
            }
            replying = false
        }
        replyText = ""
        replyFocused = false
    }

    /// A terminal agent's reply: typed into its terminal on the Mac, then shown
    /// under the card as sent (or why it was not). Its state lives on the item.
    private func sendTerminalReply(_ text: String) {
        replyText = ""
        replyFocused = false
        withAnimation(.cmuxMobileSnappy) { replying = false }
        let route = FeedRouting.shared.replyToTerminal
        store.replyToTerminal(item.id, text: text) { item, text in
            guard let route else { return "Open the terminal to reply." }
            return await route(item, text)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            // A terminal agent's question or approval is answered in its terminal (Open); its
            // finished turn or error takes a reply, typed into that terminal's agent.
            if item.takesReply {
                footerButton("bubble.left", "Reply") {
                    withAnimation(.cmuxMobileSmooth) { replying.toggle() }
                    replyFocused = replying
                }
                // One terminal reply at a time: a second would interleave with the first.
                .disabled(item.opensTerminal && item.pending != nil)
                Spacer()
            }
            footerButton("arrow.up.right.square", "Open", action: open)
            Spacer()
            footerButton(copied ? "checkmark" : "doc.on.doc", "Copy") {
                UIPasteboard.general.string = item.markdown
                if !copied { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7) }
                withAnimation(.cmuxMobileSnap) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.cmuxMobileSnap) { copied = false }
                }
            }
            Spacer()
            ShareLink(item: item.markdown) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(FooterLabelStyle())
            }
        }
        // 44 pt targets; the row keeps its 32 pt rhythm.
        .frame(height: 44)
        .padding(.vertical, -6)
        .padding(.trailing, 8)
    }

    private func footerButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(FooterLabelStyle())
        }
        .buttonStyle(.plain)
    }

    #if DEBUG
    private func runDemoCommand() {
        guard let command = director.command else { return }
        switch command {
        case .feedExpand(let id) where id == item.id:
            withAnimation(.cmuxMobileSmooth) { context.setExpanded(item.id, true) }
        case .feedReply(let id, let text) where id == item.id:
            Task {
                withAnimation(.cmuxMobileSmooth) { replying = true }
                try? await Task.sleep(for: .milliseconds(500))
                for character in text {
                    replyText.append(character)
                    try? await Task.sleep(for: .milliseconds(35))
                }
                try? await Task.sleep(for: .milliseconds(300))
                sendReply()
            }
        default:
            break
        }
    }
    #endif
}

struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 15)).contentTransition(.symbolEffect(.replace))
            configuration.title.font(.footnote)
        }
        .foregroundStyle(.secondary)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(.rect)
    }
}

/// SPEC 4.2 agent avatar: the agent glyph on `surfaceRaised`, monochrome.
struct AgentAvatar: View {
    let harness: String
    var size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color.cmuxMobileSurfaceRaised, in: .circle)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch harness {
        case "claude": "asterisk"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "cursor": "cursorarrow.rays"
        case "gemini": "sparkles"
        case "terminal": "terminal"
        default: "sparkle"
        }
    }
}

/// What every Feed row shares: the store and the screen's actions. One
/// object for the screen's life, so rows compare by identity (`FeedRow`).
@MainActor
final class FeedRowContext {
    let store: FeedStore
    /// Opens an event (set by the Feed screen; it owns the navigation path).
    var open: (FeedItem) -> Void = { _ in }
    /// Shows more or less of an event's body.
    var setExpanded: (String, Bool) -> Void = { _, _ in }

    init(store: FeedStore) {
        self.store = store
    }
}

/// One Feed row: the swipe actions around the cell. Equatable on the event
/// and its expansion only, so `.equatable()` skips every row whose event did
/// not change when the store publishes (the Mac's live events arrive several
/// times a second while an agent works).
struct FeedRow: View, Equatable {
    let item: FeedItem
    let expanded: Bool
    let context: FeedRowContext
    let swipe: FeedSwipeCoordinator

    nonisolated static func == (lhs: FeedRow, rhs: FeedRow) -> Bool {
        lhs.item == rhs.item && lhs.expanded == rhs.expanded && lhs.context === rhs.context && lhs.swipe === rhs.swipe
    }

    var body: some View {
        let context = context
        let item = item
        FeedSwipeRow(id: item.id, actions: item.swipeActions(store: context.store, open: { context.open(item) }), coordinator: swipe) {
            FeedCell(item: item, context: context, expanded: expanded)
                .background(Color.cmuxMobileBackground)
        }
    }
}

/// Where Feed actions that leave the Feed go (Reply sends into the tab's agent).
@MainActor
public final class FeedRouting {
    public static let shared = FeedRouting()
    /// Reply: the prompt goes to the item's chat, or why it can't.
    public enum ReplyOutcome {
        case sent(AgentChatStore)
        case failed(String)
    }
    var sendPrompt: ((FeedItem, String) -> ReplyOutcome)?
    /// Reply to a terminal agent's event: typed into that terminal's agent on
    /// its Mac (nil: sent; else why not). Set by the shell.
    public var replyToTerminal: ((FeedItem, String) async -> String?)?
    /// Opens a terminal agent's tab on the Workspaces tab (set by the shell).
    public var openTerminal: ((FeedItem) -> Void)?
    /// Clear All Notifications on the linked Mac (nil: no Mac can clear now).
    public var clearAllNotifications: (() async throws -> Void)?
}
#endif
