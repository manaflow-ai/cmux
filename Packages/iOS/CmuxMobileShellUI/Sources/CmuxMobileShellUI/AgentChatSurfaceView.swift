#if os(iOS)
import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI
import UIKit

/// Native renderer for a Mac-hosted agent-session surface.
///
/// The surface is intentionally a value-driven projection of the shared chat
/// protocol. It does not mirror the Mac panel's web UI: history, live events,
/// actions, and reconnect behavior all come from ``AgentChatViewModel`` and
/// the typed ``CmuxAgentChat`` models.
struct AgentChatSurfaceView: View {
    let surface: MobileSurfacePreview
    let source: MobileChatEventSource?
    let workspaceID: String?
    let preferredTerminalID: String?

    @State private var model: AgentChatViewModel

    init(
        surface: MobileSurfacePreview,
        source: MobileChatEventSource?,
        workspaceID: String?,
        preferredTerminalID: String? = nil
    ) {
        self.surface = surface
        self.source = source
        self.workspaceID = workspaceID
        self.preferredTerminalID = preferredTerminalID
        _model = State(
            initialValue: AgentChatViewModel(
                source: source,
                workspaceID: workspaceID,
                preferredTerminalID: preferredTerminalID
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            AgentChatHeader(model: model, surface: surface)
            Divider()
            timeline
            AgentChatComposer(model: model)
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            model.start()
        }
        .accessibilityIdentifier("MobileAgentChatSurface-\(surface.id.rawValue)")
    }

    @ViewBuilder
    private var timeline: some View {
        if source == nil && model.sessions.isEmpty {
            AgentChatUnavailableView()
        } else if model.sessions.isEmpty {
            AgentChatEmptySessionsView(
                isLoading: model.isLoadingSessions,
                errorMessage: model.errorMessage,
                refresh: model.refreshSessions
            )
        } else if let timeline = model.timeline {
            AgentChatTimelineView(
                timeline: timeline,
                model: model
            )
        } else {
            ProgressView("Loading conversation")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AgentChatHeader: View {
    @Bindable var model: AgentChatViewModel
    let surface: MobileSurfacePreview

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.sessions) { session in
                    Button {
                        model.select(session)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title ?? session.agentKind.displayName)
                                Text(sessionSummary(session))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                    Image(systemName: session.agentKind.systemImage)
                        }
                    }
                }
                Divider()
                Button {
                    model.refreshSessions()
                } label: {
                    Label("Refresh sessions", systemImage: "arrow.clockwise")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.selectedSession?.agentKind.systemImage ?? "bubble.left.and.bubble.right")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.selectedSession?.title ?? surface.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(model.selectedSession.map(sessionSummary) ?? "Choose a conversation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            AgentChatStateBadge(state: model.state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }

    private func sessionSummary(_ session: ChatSessionDescriptor) -> String {
        let state: String = switch session.state {
        case .idle: "Idle"
        case .working: "Working"
        case .needsInput: "Needs your input"
        case .ended: "Ended"
        }
        if let cwd = session.workingDirectory, !cwd.isEmpty {
            return "\(session.agentKind.displayName) · \(state) · \((cwd as NSString).lastPathComponent)"
        }
        return "\(session.agentKind.displayName) · \(state)"
    }
}

private extension ChatAgentKind {
    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .other: "cpu"
        }
    }
}

private struct AgentChatStateBadge: View {
    let state: ChatAgentState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .idle: "Idle"
        case .working: "Working"
        case .needsInput: "Needs input"
        case .ended: "Ended"
        }
    }

    private var color: Color {
        switch state {
        case .idle: .secondary
        case .working: .green
        case .needsInput: .orange
        case .ended: .red
        }
    }
}

private struct AgentChatTimelineView: View {
    let timeline: AgentChatTimelineState
    @Bindable var model: AgentChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if timeline.hasMoreHistory {
                        Button {
                            model.loadOlderHistory()
                        } label: {
                            HStack(spacing: 8) {
                                if timeline.isLoadingHistory {
                                    ProgressView().controlSize(.small)
                                }
                                Text("Load earlier messages")
                            }
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .disabled(timeline.isLoadingHistory)
                    }

                    ForEach(timeline.messages) { message in
                        AgentChatMessageRow(
                            message: message,
                            onAnswer: model.answer(optionIndex:),
                            onRetry: {}
                        )
                        .id(message.id)
                    }

                    ForEach(timeline.terminalBlocks) { block in
                        AgentChatTerminalBlockRow(block: block)
                            .id("terminal-\(block.id)")
                    }

                    if let streaming = timeline.streamingProse {
                        AgentChatMessageRow(
                            message: streaming,
                            isStreaming: true,
                            onAnswer: model.answer(optionIndex:),
                            onRetry: {}
                        )
                        .id("streaming-prose")
                    }

                    if let error = timeline.lastError ?? model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: timeline.messages.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: timeline.streamingProse?.kind) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo("streaming-prose", anchor: .bottom) }
            }
        }
    }
}

private struct AgentChatMessageRow: View {
    let message: ChatMessage
    var isStreaming = false
    let onAnswer: (Int) -> Void
    let onRetry: () -> Void

    var body: some View {
        if case .status(let status) = message.kind {
            statusRow(status)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if message.role == .user { Spacer(minLength: 34) }
                content
                    .frame(maxWidth: 680, alignment: .leading)
                if message.role != .user { Spacer(minLength: 34) }
            }
            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isStreaming {
                Label("Writing", systemImage: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            messageBody
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentChatMessage-\(message.id)")
    }

    @ViewBuilder
    private var messageBody: some View {
        switch message.kind {
        case .prose(let prose):
            AgentFeedMarkdownText(markdown: prose.text, font: .body)
                .fixedSize(horizontal: false, vertical: true)
        case .thought(let thought):
            VStack(alignment: .leading, spacing: 6) {
                Label("Thought", systemImage: "brain.head.profile")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                AgentFeedMarkdownText(markdown: thought.text, font: .callout, color: .secondary)
            }
        case .toolUse(let tool):
            AgentChatToolCard(tool: tool)
        case .terminal(let terminal):
            AgentChatTerminalCard(terminal: terminal)
        case .fileEdit(let edit):
            AgentChatFileEditCard(edit: edit)
        case .permissionRequest(let permission):
            AgentChatPermissionCard(permission: permission, onAnswer: onAnswer)
        case .question(let question):
            AgentChatQuestionCard(question: question, onAnswer: onAnswer)
        case .status:
            EmptyView()
        case .attachment(let attachment):
            Label(attachment.displayName ?? "Attachment", systemImage: attachment.media == .image ? "photo" : "doc")
                .font(.body.weight(.medium))
        case .unsupported(let unsupported):
            VStack(alignment: .leading, spacing: 4) {
                Label("Unsupported update", systemImage: "questionmark.diamond")
                    .font(.caption.weight(.semibold))
                Text(unsupported.rawType)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(_ status: ChatStatusTransition) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.event.systemImage)
            Text(status.detail ?? status.event.label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: Color.accentColor.opacity(0.16)
        case .agent: Color.secondary.opacity(0.09)
        case .system: Color.secondary.opacity(0.07)
        }
    }

    private var borderColor: Color {
        message.role == .user ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.14)
    }
}

private extension ChatStatusTransition.Event {
    var label: String {
        switch self {
        case .sessionStarted: "Session started"
        case .sessionEnded: "Session ended"
        case .interrupted: "Interrupted"
        case .contextCompacted: "Context compacted"
        }
    }

    var systemImage: String {
        switch self {
        case .sessionStarted: "play.circle"
        case .sessionEnded: "stop.circle"
        case .interrupted: "pause.circle"
        case .contextCompacted: "arrow.down.right.and.arrow.up.left"
        }
    }
}

private struct AgentChatToolCard: View {
    let tool: ChatToolUse

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: tool.status == .running ? "gearshape.2" : tool.status == .failed ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(tool.status == .failed ? .red : tool.status == .running ? .orange : .green)
                Text(tool.toolName)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(tool.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(tool.summary)
                .font(.callout)
            if let input = tool.inputDetail, !input.isEmpty {
                AgentChatCodeText(input)
            }
            if let output = tool.output, !output.isEmpty {
                AgentChatCodeText(output)
            }
        }
    }
}

private extension ChatToolUse.Status {
    var label: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        }
    }
}

private struct AgentChatTerminalCard: View {
    let terminal: ChatTerminalCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: terminal.isRunning ? "terminal" : terminal.exitCode == 0 ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(terminal.isRunning ? .orange : terminal.exitCode == 0 ? .green : .red)
                Text(terminal.command)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(2)
            }
            if let output = terminal.output, !output.isEmpty {
                AgentChatCodeText(output)
            }
            if let duration = terminal.durationSeconds {
                Text(String(format: "%.1fs", duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AgentChatTerminalBlockRow: View {
    let block: TerminalCommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: block.isInteractive ? "rectangle.on.rectangle" : "terminal")
                Text(block.command.isEmpty ? "Shell" : block.command)
                    .font(.callout.monospaced().weight(.semibold))
                Spacer()
                if let code = block.exitCode {
                    Text("exit \(code)")
                        .font(.caption.monospaced())
                        .foregroundStyle(block.failed ? .red : .secondary)
                } else if block.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
            if !block.output.isEmpty {
                AgentChatCodeText(block.output)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AgentChatFileEditCard: View {
    let edit: ChatFileEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: edit.operation.systemImage)
                    .foregroundStyle(edit.operation == .delete ? .red : .green)
                Text(edit.filePath)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Text(edit.operation.label)
                if let additions = edit.additions { Text("+\(additions)").foregroundStyle(.green) }
                if let deletions = edit.deletions { Text("-\(deletions)").foregroundStyle(.red) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let diff = edit.unifiedDiff, !diff.isEmpty {
                AgentChatCodeText(diff)
            }
        }
    }
}

private extension ChatFileEdit.Operation {
    var label: String {
        switch self {
        case .edit: "Edited"
        case .write: "Wrote"
        case .delete: "Deleted"
        }
    }

    var systemImage: String {
        switch self {
        case .edit: "pencil"
        case .write: "doc.badge.plus"
        case .delete: "trash"
        }
    }
}

private struct AgentChatPermissionCard: View {
    let permission: ChatPermissionRequest
    let onAnswer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(permission.title, systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            AgentChatCodeText(permission.subject)
            if let resolution = permission.resolution {
                Label(resolution.label, systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button("Allow") { onAnswer(0) }
                        .buttonStyle(.borderedProminent)
                    Button("Deny") { onAnswer(1) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

private extension ChatPermissionRequest.Resolution {
    var label: String {
        switch self {
        case .approved: "Allowed"
        case .denied: "Denied"
        case .expired: "Expired"
        }
    }
}

private struct AgentChatQuestionCard: View {
    let question: ChatQuestion
    let onAnswer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Question", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
            AgentFeedMarkdownText(markdown: question.prompt, font: .body)
            if let selected = question.selectedOptionLabel {
                Label("Selected: \(selected)", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button {
                        onAnswer(index)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .frame(width: 22, height: 22)
                                .background(Color.accentColor.opacity(0.14), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.callout.weight(.medium))
                                if let detail = option.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct AgentChatCodeText: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct AgentChatComposer: View {
    @Bindable var model: AgentChatViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the agent", text: $model.composerText, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .onSubmit { model.send() }

            if model.canInterrupt {
                Button {
                    model.interrupt()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .contextMenu {
                    Button("Hard interrupt", role: .destructive) {
                        model.interrupt(hard: true)
                    }
                }
                .accessibilityLabel("Stop agent")
            } else {
                Button {
                    model.send()
                } label: {
                    if model.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .frame(width: 36, height: 36)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct AgentChatUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "Connect to your Mac",
            systemImage: "wifi.exclamationmark",
            description: Text("Reconnect to load this agent session.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentChatEmptySessionsView: View {
    let isLoading: Bool
    let errorMessage: String?
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(errorMessage ?? "No agent conversations found")
                    .font(.headline)
                Text("Start Claude, Codex, or another supported agent in this workspace, then refresh.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Refresh sessions", action: refresh)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
