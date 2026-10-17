import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import PhotosUI
import SwiftUI
import UIKit

/// A dedicated ChatGPT/Codex-style mobile mode for coding-agent sessions.
/// It intentionally lives in a sheet so the existing workspace and Feed
/// navigation remain available while a user triages an agent turn.
struct AgentChatModeView: View {
    @Bindable var store: CMUXMobileShellStore
    @State private var model = AgentChatModeModel()
    @State private var isShowingSessionList = true

    var body: some View {
        NavigationStack {
            AgentChatTranscriptView(model: model)
                .navigationTitle(model.selectedSession?.title ?? "Agents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isShowingSessionList = true
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                        .accessibilityLabel("Agent sessions")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Refresh") { Task { await model.refresh() } }
                            Picker("Provider", selection: $model.selectedProvider) {
                                Text("All agents").tag("all")
                                Text("Claude Code").tag("claude")
                                Text("Codex").tag("codex")
                                Text("OpenCode").tag("opencode")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Agent mode options")
                    }
                }
                .sheet(isPresented: $isShowingSessionList) {
                    AgentChatSessionList(model: model)
                        .presentationDetents([.medium, .large])
                }
        }
        .task {
            model.updateSource(store.makeChatEventSource())
        }
        .onChange(of: store.connectionState) { _, _ in
            model.updateSource(store.makeChatEventSource())
        }
        .alert("Agent mode error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

private struct AgentChatSessionList: View {
    @Bindable var model: AgentChatModeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.visibleSessions.isEmpty {
                    ContentUnavailableView("No agent sessions", systemImage: "sparkles", description: Text("Start Claude Code, Codex, or OpenCode in cmux."))
                } else {
                    ForEach(model.visibleSessions) { session in
                        Button {
                            model.select(session)
                            dismiss()
                        } label: {
                            AgentChatSessionRow(session: session, isSelected: session.id == model.selectedSessionID)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct AgentChatSessionRow: View {
    let session: ChatSessionDescriptor
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title ?? session.agentKind.displayName)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(session.agentKind.displayName)
                    if let cwd = session.workingDirectory {
                        Text(cwd)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            AgentStatusIndicator(state: session.state)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if isSelected { Capsule().fill(.tint).frame(width: 3) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.agentKind.displayName), \(session.title ?? "Untitled session")")
    }

    private var iconName: String {
        switch session.agentKind.sourceName {
        case "claude": return "c.circle.fill"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "square.stack.3d.up.fill"
        default: return "sparkles"
        }
    }

    private var iconColor: Color {
        switch session.agentKind.sourceName {
        case "claude": return .orange
        case "codex": return .green
        case "opencode": return .purple
        default: return .accentColor
        }
    }
}

private struct AgentStatusIndicator: View {
    let state: ChatAgentState

    var body: some View {
        Group {
            switch state {
            case .working: ProgressView().controlSize(.small)
            case .needsInput: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .idle: Circle().fill(.secondary).frame(width: 8, height: 8)
            case .ended: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .idle: return "Idle"
        case .ended: return "Ended"
        }
    }
}

private struct AgentChatTranscriptView: View {
    @Bindable var model: AgentChatModeModel
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.selectedSession {
                AgentExecutionContextBar(session: session)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.selectedHasMoreHistory {
                            Button {
                                Task { await model.loadOlderMessages() }
                            } label: {
                                Label("Load earlier messages", systemImage: "chevron.up")
                                    .font(.footnote.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.bottom, 2)
                        }
                        if model.selectedMessages.isEmpty,
                           model.selectedTerminalBlocks.isEmpty,
                           model.selectedStreamingMessage == nil {
                            ContentUnavailableView("Start a task", systemImage: "sparkles", description: Text("Ask your coding agent to inspect, change, or explain your project."))
                                .padding(.top, 80)
                        } else {
                            if model.selectedSession?.kind == .terminal {
                                ForEach(model.selectedTerminalBlocks) { block in
                                    AgentTerminalBlockView(block: block)
                                        .id("terminal-\(block.id)")
                                }
                            }
                            ForEach(model.selectedMessages) { message in
                                AgentChatMessageView(message: message, answer: { index in
                                    Task { await model.answer(optionIndex: index) }
                                })
                                .id(message.id)
                            }
                            if let streaming = model.selectedStreamingMessage {
                                AgentChatMessageView(message: streaming, isStreaming: true)
                                    .id("streaming")
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.selectedMessages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.selectedStreamingMessage?.id) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            AgentChatComposer(model: model, focused: $composerFocused)
        }
        .background(Color(.systemBackground))
        .refreshable { await model.refresh() }
    }
}

private struct AgentExecutionContextBar: View {
    let session: ChatSessionDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(session.agentKind.displayName, systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                AgentStatusIndicator(state: session.state)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    AgentContextPill(
                        title: session.title ?? "Untitled task",
                        subtitle: "Project",
                        systemImage: "folder"
                    )
                    if let workspaceID = session.workspaceID {
                        AgentContextPill(
                            title: workspaceID,
                            subtitle: "Workspace",
                            systemImage: "square.grid.2x2"
                        )
                    }
                    if let terminalID = session.terminalID {
                        AgentContextPill(
                            title: terminalID,
                            subtitle: "Host",
                            systemImage: "desktopcomputer"
                        )
                    }
                    if let cwd = session.workingDirectory {
                        AgentContextPill(
                            title: cwd,
                            subtitle: "Worktree",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentContextPill: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(subtitle.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct AgentChatMessageView: View {
    let message: ChatMessage
    var isStreaming = false
    var answer: ((Int) -> Void)?

    var body: some View {
        switch message.kind {
        case .prose(let prose):
            AgentProseBubble(text: prose.text, role: message.role, isStreaming: isStreaming)
        case .thought(let thought):
            AgentThoughtCard(text: thought.text)
        case .toolUse(let tool):
            AgentToolCard(tool: tool)
        case .terminal(let terminal):
            AgentTerminalCard(terminal: terminal)
        case .fileEdit(let edit):
            AgentDiffCard(edit: edit)
        case .permissionRequest(let request):
            AgentPermissionCard(request: request, answer: answer)
        case .question(let question):
            AgentQuestionCard(question: question, answer: answer)
        case .status(let status):
            Text(status.detail ?? status.event.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .attachment(let attachment):
            Label(attachment.displayName ?? "Attachment", systemImage: attachment.media == .image ? "photo" : "doc")
                .font(.subheadline)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .unsupported(let payload):
            Label("Unsupported agent event: \(payload.rawType)", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AgentProseBubble: View {
    let text: String
    let role: ChatRole
    let isStreaming: Bool

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 36) }
            AgentFeedMarkdownText(
                markdown: text,
                font: role == .user ? .body : .body,
                color: role == .user ? .white : .primary
            )
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(role == .user ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(role == .user ? .white : .primary)
                .opacity(isStreaming ? 0.9 : 1)
            if role != .user { Spacer(minLength: 36) }
        }
    }
}

private struct AgentTerminalBlockView: View {
    let block: TerminalCommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: block.isInteractive ? "rectangle.inset.filled" : "terminal")
                Text(block.command.isEmpty ? "Shell" : block.command)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if block.isRunning {
                    ProgressView().controlSize(.mini)
                } else if let exitCode = block.exitCode {
                    Text("Exit \(exitCode)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(block.failed ? .red : .green)
                }
            }
            if !block.output.isEmpty {
                Text(block.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentThoughtCard: View {
    let text: String
    var body: some View {
        DisclosureGroup("Thinking") { Text(text).font(.caption).foregroundStyle(.secondary) }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AgentToolCard: View {
    let tool: ChatToolUse
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(tool.summary, systemImage: tool.status == .running ? "arrow.triangle.2.circlepath" : "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
            if let output = tool.output { Text(output).font(.caption.monospaced()).lineLimit(8) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AgentTerminalCard: View {
    let terminal: ChatTerminalCapture
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(terminal.command, systemImage: "terminal")
                .font(.caption.monospaced().weight(.semibold))
            if let output = terminal.output { Text(output).font(.caption.monospaced()).textSelection(.enabled) }
            if let exitCode = terminal.exitCode { Text("Exit \(exitCode)").font(.caption2).foregroundStyle(exitCode == 0 ? .green : .red) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }
}

private struct AgentDiffCard: View {
    let edit: ChatFileEdit
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(edit.filePath, systemImage: "doc.text")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let additions = edit.additions { Text("+\(additions)").foregroundStyle(.green) }
                if let deletions = edit.deletions { Text("-\(deletions)").foregroundStyle(.red) }
            }
            if let diff = edit.unifiedDiff { Text(diff).font(.caption2.monospaced()).lineLimit(12) }
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AgentPermissionCard: View {
    let request: ChatPermissionRequest
    let answer: ((Int) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "hand.raised.fill")
                .font(.headline)
            Text(request.subject).font(.caption.monospaced()).textSelection(.enabled)
            if let resolution = request.resolution {
                Text(resolution.rawValue.capitalized).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Approve") { answer?(0) }.buttonStyle(.borderedProminent)
                    Button("Deny") { answer?(1) }.buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AgentQuestionCard: View {
    let question: ChatQuestion
    let answer: ((Int) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.prompt).font(.headline)
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    answer?(index)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.label).font(.subheadline.weight(.semibold))
                        if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AgentChatComposer: View {
    @Bindable var model: AgentChatModeModel
    var focused: FocusState<Bool>.Binding
    @State private var isPhotoPickerPresented = false
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 6) {
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { attachment in
                            AgentChatAttachmentChip(attachment: attachment) {
                                model.removeAttachment(id: attachment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        isPhotoPickerPresented = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        Task { await model.stagePastedImages() }
                    } label: {
                        Label("Paste Image", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Add attachment")
                .disabled(model.attachments.count >= 10)
                TextField("Message your agent", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused(focused)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                if model.selectedSession?.isWorking == true {
                    Button { Task { await model.interrupt() } } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                    .foregroundStyle(.red)
                    .accessibilityLabel("Stop agent")
                } else {
                    Button { Task { await model.sendDraft() } } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .foregroundStyle(
                        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty
                            ? Color.secondary : Color.accentColor
                    )
                    .disabled(
                        model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && model.attachments.isEmpty
                    )
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoSelection,
            maxSelectionCount: max(1, 10 - model.attachments.count),
            matching: .images
        )
        .onChange(of: photoSelection) { items in
            guard !items.isEmpty else { return }
            Task {
                await stagePhotos(items)
                photoSelection = []
            }
        }
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) async {
        let remaining = max(0, 10 - model.attachments.count)
        guard remaining > 0 else { return }
        for item in items.prefix(remaining) {
            guard !Task.isCancelled else { return }
            do {
                guard let imported = try await ImportedPhotoLibraryFile.load(item) else { continue }
                defer { try? FileManager.default.removeItem(at: imported.url) }
                guard imported.kind == .image,
                      let prepared = await MobileImageAttachmentPreparer().prepare(url: imported.url) else {
                    continue
                }
                let format: ChatOutboundAttachment.Format =
                    ["jpg", "jpeg"].contains(prepared.format.lowercased()) ? .jpeg : .png
                let stem = (imported.originalFileName as NSString).deletingPathExtension
                model.addAttachment(.init(
                    displayName: (stem.isEmpty ? "image" : stem) + (format == .jpeg ? ".jpeg" : ".png"),
                    data: prepared.data,
                    format: format,
                    thumbnailData: prepared.thumbnailData
                ))
            } catch is CancellationError {
                return
            } catch { continue }
        }
    }
}

private struct AgentChatAttachmentChip: View {
    let attachment: AgentChatModeModel.PendingAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let image = UIImage(data: attachment.thumbnailData ?? attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .frame(width: 42, height: 42)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private extension ChatSessionDescriptor {
    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }
}
