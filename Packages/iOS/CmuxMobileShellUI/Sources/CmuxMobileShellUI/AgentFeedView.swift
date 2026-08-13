#if os(iOS)
import CmuxAgentChat
import CmuxMobileSupport
import Foundation
import SwiftUI
import UIKit

/// The cross-agent Feed surface. It reads like a social timeline, while every
/// card remains a real coding surface: questions, permissions, diffs, command
/// output, artifacts, and replies stay actionable in place.
struct AgentFeedView: View {
    @Bindable var store: AgentFeedStore
    let variantOverride: AgentFeedVariant?
    let onOpenWorkspace: (AgentFeedEntry) -> Void
    let onOpenTerminal: (AgentFeedEntry) -> Void

    @Environment(MobileDisplaySettings.self) private var displaySettings: MobileDisplaySettings?
    @State private var composerText = ""
    @State private var selectedSessionID: String?
    @State private var selectedDetail: AgentFeedDetail?
    @FocusState private var composerFocused: Bool

    init(
        store: AgentFeedStore,
        variant: AgentFeedVariant? = nil,
        onOpenWorkspace: @escaping (AgentFeedEntry) -> Void = { _ in },
        onOpenTerminal: @escaping (AgentFeedEntry) -> Void = { _ in }
    ) {
        self.store = store
        variantOverride = variant
        self.onOpenWorkspace = onOpenWorkspace
        self.onOpenTerminal = onOpenTerminal
    }

    private var variant: AgentFeedVariant {
        variantOverride ?? displaySettings?.agentFeedVariant ?? .orbit
    }

    private var activeSessionID: String? {
        if let selectedSessionID, store.sessions.contains(where: { $0.id == selectedSessionID }) {
            return selectedSessionID
        }
        return store.entries.first(where: { !$0.isPresence })?.sessionID ?? store.sessions.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            feedHeader
            if store.isLoading, store.entries.isEmpty {
                loadingState
            } else if filteredEntries.isEmpty {
                emptyState
            } else {
                timeline
            }
        }
        .background {
            Rectangle()
                .fill(feedBackground)
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .sheet(item: $selectedDetail) { detail in
            AgentFeedDetailView(detail: detail)
        }
        .accessibilityIdentifier("AgentFeedView")
    }

    private var feedHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("mobile.feed.title", defaultValue: "Feed"))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(store.isFixture
                        ? L10n.string("mobile.feed.labPreview", defaultValue: "Labs preview")
                        : L10n.string("mobile.feed.subtitle", defaultValue: "Every agent turn, in one place"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: variant.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(variantAccent)
                    .frame(width: 42, height: 42)
                    .background(variantAccent.opacity(0.14), in: Circle())
                    .accessibilityLabel(variant.title)
            }

            if !store.sessions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        feedFilterChip(
                            title: L10n.string("mobile.feed.filter.all", defaultValue: "All agents"),
                            symbol: "person.3",
                            isSelected: selectedSessionID == nil
                        ) {
                            selectedSessionID = nil
                        }
                        ForEach(store.sessions) { session in
                            feedFilterChip(
                                title: session.agentKind.displayName,
                                symbol: session.agentKind == .codex ? "command" : "sparkle",
                                isSelected: selectedSessionID == session.id
                            ) {
                                selectedSessionID = session.id
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func feedFilterChip(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? variantAccent : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: variant == .pulse ? 8 : 14) {
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 18)
                }

                ForEach(filteredEntries) { entry in
                    AgentFeedCard(
                        entry: entry,
                        variant: variant,
                        onAnswer: { optionIndex in
                            Task {
                                await store.answer(
                                    optionIndex: optionIndex,
                                    in: entry.sessionID,
                                    messageID: entry.message?.id
                                )
                            }
                        },
                        onInterrupt: {
                            Task { await store.interrupt(sessionID: entry.sessionID) }
                        },
                        onReply: {
                            selectedSessionID = entry.sessionID
                            composerFocused = true
                        },
                        onInspect: { detail in
                            selectedDetail = detail
                        },
                        onOpenWorkspace: entry.workspaceID == nil
                            ? nil
                            : { onOpenWorkspace(entry) },
                        onOpenTerminal: entry.workspaceID == nil || entry.terminalID == nil
                            ? nil
                            : { onOpenTerminal(entry) }
                    )
                    .padding(.horizontal, 14)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 14)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var filteredEntries: [AgentFeedEntry] {
        guard let selectedSessionID else { return store.entries }
        return store.entries.filter { $0.sessionID == selectedSessionID }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.feed.empty.title", defaultValue: "No agent activity yet"),
                systemImage: "sparkles"
            )
        } description: {
            Text(L10n.string(
                "mobile.feed.empty.description",
                defaultValue: "Start a coding session and its turns will appear here."
            ))
        } actions: {
            Button(L10n.string("mobile.feed.empty.retry", defaultValue: "Refresh")) {
                Task { await store.retry() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(variantAccent)
            Text(L10n.string(
                "mobile.feed.loading",
                defaultValue: "Loading agent activity…"
            ))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("AgentFeedLoading")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if let activeSessionID,
               let session = store.descriptor(for: activeSessionID) {
                Menu {
                    ForEach(store.sessions) { option in
                        Button {
                            selectedSessionID = option.id
                        } label: {
                            Label(
                                option.agentKind.displayName,
                                systemImage: option.id == activeSessionID ? "checkmark" : "circle"
                            )
                        }
                    }
                } label: {
                    Image(systemName: session.agentKind == .codex ? "command" : "sparkle")
                        .font(.headline)
                        .foregroundStyle(variantAccent)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel(L10n.string("mobile.feed.composer.target", defaultValue: "Reply target"))
            }

            TextField(
                L10n.string("mobile.feed.composer.placeholder", defaultValue: "Reply to an agent…"),
                text: $composerText,
                axis: .vertical
            )
            .lineLimit(1...5)
            .focused($composerFocused)
            .submitLabel(.send)
            .onSubmit { sendComposer() }

            Button(action: sendComposer) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? variantAccent : .secondary)
            }
            .disabled(!canSend)
            .accessibilityLabel(L10n.string("mobile.feed.composer.send", defaultValue: "Send reply"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var canSend: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activeSessionID != nil
    }

    private func sendComposer() {
        guard let activeSessionID, canSend else { return }
        let text = composerText
        composerText = ""
        Task { await store.send(text, to: activeSessionID) }
    }

    private var feedBackground: AnyShapeStyle {
        switch variant {
        case .orbit: AnyShapeStyle(Color(uiColor: .systemGroupedBackground))
        case .signal: AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        case .commandDeck: AnyShapeStyle(Color(red: 0.035, green: 0.05, blue: 0.08))
        case .prism: AnyShapeStyle(LinearGradient(colors: [Color.indigo.opacity(0.08), Color.cyan.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .pulse: AnyShapeStyle(Color(uiColor: .systemBackground))
        }
    }

    private var variantAccent: Color {
        switch variant {
        case .orbit: .indigo
        case .signal: .orange
        case .commandDeck: .green
        case .prism: .purple
        case .pulse: .pink
        }
    }
}

private struct AgentFeedCard: View {
    let entry: AgentFeedEntry
    let variant: AgentFeedVariant
    let onAnswer: (Int) -> Void
    let onInterrupt: () -> Void
    let onReply: () -> Void
    let onInspect: (AgentFeedDetail) -> Void
    let onOpenWorkspace: (() -> Void)?
    let onOpenTerminal: (() -> Void)?

    var body: some View {
        switch variant {
        case .orbit:
            orbitCard
        case .signal:
            signalCard
        case .commandDeck:
            commandDeckCard
        case .prism:
            prismCard
        case .pulse:
            pulseCard
        }
    }

    private var primitive: some View {
        AgentFeedPrimitiveView(
            entry: entry,
            accent: accent,
            onAnswer: onAnswer,
            onInterrupt: onInterrupt,
            onReply: onReply,
            onInspect: onInspect,
            onOpenWorkspace: onOpenWorkspace,
            onOpenTerminal: onOpenTerminal
        )
    }

    private var orbitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader
            primitive
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [accent.opacity(0.55), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
        .shadow(color: accent.opacity(0.08), radius: 14, y: 6)
    }

    private var signalCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(accent).frame(width: 4)
            VStack(alignment: .leading, spacing: 9) {
                cardHeader
                primitive
            }
        }
        .padding(13)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var commandDeckCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader
            primitive
        }
        .padding(13)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.22), lineWidth: 1))
        .foregroundStyle(.white)
        .font(.system(.subheadline, design: .monospaced))
    }

    private var prismCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader
            primitive
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.16), .clear, Color.cyan.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var pulseCard: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Circle().fill(accent).frame(width: 10, height: 10)
                Rectangle().fill(accent.opacity(0.22)).frame(width: 2)
            }
            VStack(alignment: .leading, spacing: 7) {
                cardHeader
                primitive
            }
        }
        .padding(.vertical, 6)
    }

    private var cardHeader: some View {
        HStack(spacing: 9) {
            Text(String(entry.agentName.prefix(1)).uppercased())
                .font(.caption.weight(.bold))
                .frame(width: 28, height: 28)
                .background(accent.opacity(0.18), in: Circle())
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.agentName).font(.subheadline.weight(.semibold))
                HStack(spacing: 5) {
                    Text(entry.workspaceName)
                    Text(L10n.string("mobile.feed.meta.separator", defaultValue: "·"))
                    Text(entry.timestamp, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.requiresReply {
                Text(L10n.string("mobile.feed.needsReply", defaultValue: "NEEDS YOU"))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(accent.opacity(0.13), in: Capsule())
            } else if entry.isStreaming {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var accent: Color {
        switch variant {
        case .orbit: .indigo
        case .signal: .orange
        case .commandDeck: .green
        case .prism: .purple
        case .pulse: .pink
        }
    }
}

private struct AgentFeedPrimitiveView: View {
    let entry: AgentFeedEntry
    let accent: Color
    let onAnswer: (Int) -> Void
    let onInterrupt: () -> Void
    let onReply: () -> Void
    let onInspect: (AgentFeedDetail) -> Void
    let onOpenWorkspace: (() -> Void)?
    let onOpenTerminal: (() -> Void)?

    var body: some View {
        switch entry.content {
        case .message(let message): messageView(message)
        case .terminalBlock(let block): terminalBlockView(block)
        case .presence(let state): presenceView(state)
        }
    }

    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        switch message.kind {
        case .prose(let prose):
            VStack(alignment: .leading, spacing: 10) {
                Text(prose.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                actionRow(copyText: prose.text)
            }
        case .thought(let thought):
            VStack(alignment: .leading, spacing: 9) {
                disclosureRow(
                    title: L10n.string("mobile.feed.primitive.thought", defaultValue: "Thought"),
                    symbol: "brain.head.profile",
                    text: thought.text
                )
                actionRow(copyText: thought.text)
            }
        case .toolUse(let tool):
            VStack(alignment: .leading, spacing: 8) {
                Label(tool.toolName, systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
                Text(tool.summary).fixedSize(horizontal: false, vertical: true)
                if let output = tool.output, !output.isEmpty {
                    Text(output).font(.caption.monospaced()).lineLimit(4)
                }
                HStack {
                    primitiveButton("mobile.feed.action.inspect", fallback: "Inspect", symbol: "arrow.up.right.square") {
                        onInspect(AgentFeedDetail(title: tool.toolName, body: [tool.inputDetail, tool.output].compactMap { $0 }.joined(separator: "\n\n")))
                    }
                    if let path = tool.referencedPaths?.first,
                       let onOpenWorkspace {
                        primitiveButton("mobile.feed.action.openWorkspace", fallback: "Open workspace", symbol: "rectangle.stack") {
                            onOpenWorkspace()
                        }
                        .accessibilityHint(Text(path))
                    }
                }
                actionRow(copyText: tool.output ?? tool.summary)
            }
        case .terminal(let terminal):
            VStack(alignment: .leading, spacing: 8) {
                Label(terminal.command, systemImage: terminal.isRunning ? "play.fill" : "terminal")
                    .font(.subheadline.monospaced().weight(.semibold))
                if let output = terminal.output, !output.isEmpty {
                    Text(output).font(.caption.monospaced()).lineLimit(8).textSelection(.enabled)
                }
                HStack {
                    if let onOpenTerminal {
                        primitiveButton("mobile.feed.action.openTerminal", fallback: "Open terminal", symbol: "rectangle.split.3x1") {
                            onOpenTerminal()
                        }
                    }
                }
                actionRow(copyText: [terminal.command, terminal.output].compactMap { $0 }.joined(separator: "\n"))
            }
        case .fileEdit(let edit):
            VStack(alignment: .leading, spacing: 8) {
                Label(edit.filePath, systemImage: edit.operation == .delete ? "trash" : "doc.badge.plus")
                    .font(.subheadline.monospaced().weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if let additions = edit.additions { Text("+\(additions)").foregroundStyle(.green) }
                    if let deletions = edit.deletions { Text("−\(deletions)").foregroundStyle(.red) }
                    Spacer()
                    primitiveButton("mobile.feed.action.viewDiff", fallback: "View diff", symbol: "doc.text.magnifyingglass") {
                        onInspect(AgentFeedDetail(title: edit.filePath, body: edit.unifiedDiff ?? L10n.string("mobile.feed.diffUnavailable", defaultValue: "Diff unavailable")))
                    }
                }
                actionRow(copyText: edit.unifiedDiff ?? edit.filePath)
            }
        case .permissionRequest(let request):
            VStack(alignment: .leading, spacing: 9) {
                Label(request.title, systemImage: request.resolution == nil ? "lock.open" : "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                Text(request.subject).font(.system(.body, design: .monospaced))
                if let resolution = request.resolution {
                    Text(permissionResolutionLabel(resolution)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    HStack {
                        primitiveButton("mobile.feed.action.allow", fallback: "Allow", symbol: "checkmark") { onAnswer(0) }
                        primitiveButton("mobile.feed.action.deny", fallback: "Deny", symbol: "xmark") { onAnswer(1) }
                    }
                }
                actionRow(copyText: request.subject)
            }
        case .question(let question):
            VStack(alignment: .leading, spacing: 9) {
                Label(question.prompt, systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        onAnswer(index)
                    } label: {
                        HStack {
                            Text(option.label).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: question.selectedOptionLabel == option.label ? "checkmark.circle.fill" : "circle")
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(accent.opacity(question.selectedOptionLabel == option.label ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(question.selectedOptionLabel != nil)
                }
                actionRow(copyText: question.prompt)
            }
        case .status(let status):
            VStack(alignment: .leading, spacing: 8) {
                Label(statusLabel(status), systemImage: statusSymbol(status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let detail = status.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                actionRow(copyText: status.detail ?? statusLabel(status))
            }
        case .attachment(let attachment):
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    onInspect(AgentFeedDetail(
                        title: attachment.displayName ?? L10n.string("mobile.feed.attachment.title", defaultValue: "Attachment"),
                        body: attachment.hostPath ?? L10n.string("mobile.feed.attachment.noPath", defaultValue: "Attachment metadata only")
                    ))
                } label: {
                    Label(attachment.displayName ?? L10n.string("mobile.feed.attachment.file", defaultValue: "Attached file"), systemImage: attachment.media == .image ? "photo" : "paperclip")
                }
                .buttonStyle(.bordered)
                actionRow(copyText: attachment.hostPath ?? attachment.displayName)
            }
        case .unsupported(let payload):
            VStack(alignment: .leading, spacing: 7) {
                Label(L10n.string("mobile.feed.primitive.unsupported", defaultValue: "Unsupported coding event"), systemImage: "questionmark.square.dashed")
                Text(payload.rawType).font(.caption.monospaced()).foregroundStyle(.secondary)
                primitiveButton("mobile.feed.action.inspect", fallback: "Inspect", symbol: "arrow.up.right.square") {
                    onInspect(AgentFeedDetail(title: payload.rawType, body: L10n.string("mobile.feed.unsupportedBody", defaultValue: "This event came from a newer agent runtime.")))
                }
                actionRow(copyText: payload.rawType)
            }
        }
    }

    private func terminalBlockView(_ block: TerminalCommandBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(block.command.isEmpty ? L10n.string("mobile.feed.terminal.prompt", defaultValue: "Terminal prompt") : block.command, systemImage: block.isInteractive ? "rectangle.inset.filled" : "terminal")
                .font(.subheadline.monospaced().weight(.semibold))
            if !block.output.isEmpty {
                Text(block.output).font(.caption.monospaced()).lineLimit(8).textSelection(.enabled)
            }
            HStack {
                if let onOpenTerminal {
                    primitiveButton("mobile.feed.action.openTerminal", fallback: "Open terminal", symbol: "rectangle.split.3x1") { onOpenTerminal() }
                }
            }
            actionRow(copyText: [block.command, block.output].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }

    private func presenceView(_ state: ChatAgentState) -> some View {
        HStack(spacing: 9) {
            Image(systemName: presenceSymbol(for: state)).foregroundStyle(accent)
            Text(presenceTitle(for: state))
                .font(.subheadline.weight(.medium))
            Spacer()
            primitiveButton("mobile.feed.action.reply", fallback: "Reply", symbol: "arrow.turn.up.left") { onReply() }
        }
    }

    private func presenceTitle(for state: ChatAgentState) -> String {
        switch state {
        case .idle:
            L10n.string(
                "mobile.feed.presence.turnFinished",
                defaultValue: "Turn finished. This agent expects your next input."
            )
        default:
            L10n.string(
                "mobile.feed.presence.needsInput",
                defaultValue: "This agent is waiting for your next input."
            )
        }
    }

    private func presenceSymbol(for state: ChatAgentState) -> String {
        if case .idle = state { return "checkmark.circle.fill" }
        return "hand.wave.fill"
    }

    private func disclosureRow(title: String, symbol: String, text: String) -> some View {
        DisclosureGroup {
            Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
        }
    }

    private func actionRow(copyText: String? = nil) -> some View {
        HStack {
            primitiveButton("mobile.feed.action.reply", fallback: "Reply", symbol: "arrow.turn.up.left") { onReply() }
            if let copyText, !copyText.isEmpty {
                primitiveButton("mobile.feed.action.copy", fallback: "Copy", symbol: "doc.on.doc") { UIPasteboard.general.string = copyText }
            }
            Spacer()
            if (entry.message?.role == .agent || entry.terminalBlock != nil), case .working = entry.state {
                primitiveButton("mobile.feed.action.stop", fallback: "Stop", symbol: "stop.circle") { onInterrupt() }
            }
        }
    }

    private func primitiveButton(
        _ key: StaticString,
        fallback: String.LocalizationValue,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(L10n.string(key, defaultValue: fallback), systemImage: symbol)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func permissionResolutionLabel(_ resolution: ChatPermissionRequest.Resolution) -> String {
        switch resolution {
        case .approved: L10n.string("mobile.feed.permission.approved", defaultValue: "Allowed")
        case .denied: L10n.string("mobile.feed.permission.denied", defaultValue: "Denied")
        case .expired: L10n.string("mobile.feed.permission.expired", defaultValue: "Expired")
        }
    }

    private func statusLabel(_ status: ChatStatusTransition) -> String {
        switch status.event {
        case .sessionStarted: L10n.string("mobile.feed.status.started", defaultValue: "Session started")
        case .sessionEnded: L10n.string("mobile.feed.status.ended", defaultValue: "Session ended")
        case .interrupted: L10n.string("mobile.feed.status.interrupted", defaultValue: "Turn interrupted")
        case .contextCompacted: L10n.string("mobile.feed.status.compacted", defaultValue: "Context compacted")
        }
    }

    private func statusSymbol(_ status: ChatStatusTransition) -> String {
        switch status.event {
        case .sessionStarted: "play.circle"
        case .sessionEnded: "checkmark.circle"
        case .interrupted: "pause.circle"
        case .contextCompacted: "arrow.down.right.and.arrow.up.left"
        }
    }
}

private struct AgentFeedDetail: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

private struct AgentFeedDetailView: View {
    let detail: AgentFeedDetail
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(detail.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .padding(18)
            }
            .navigationTitle(detail.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.feed.action.done", defaultValue: "Done")) { dismiss() }
                }
            }
        }
    }
}
#endif
