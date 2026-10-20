#if os(iOS)
import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A native ChatGPT-style shell for a Mac-hosted coding-agent conversation.
///
/// The visual contract follows the current ChatGPT iOS app: a quiet white
/// transcript, pastel user bubbles, plain assistant prose, a top model picker,
/// a history drawer, message actions, and the floating rounded composer. The
/// content still comes from the typed `CmuxAgentChat` protocol, so Codex,
/// Claude Code, and OpenCode share one renderer without falling back to the
/// old web/session GUI.
struct AgentChatSurfaceView: View {
    let surface: MobileSurfacePreview
    let source: MobileChatEventSource?
    let workspaceID: String?
    let preferredTerminalID: String?

    @State private var model: AgentChatViewModel
    @State private var isHistoryPresented = false
    @State private var isAgentPickerPresented = false
    @State private var isInfoPresented = false
    @State private var shouldFocusComposer = false

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
            ChatGPTAgentTopBar(
                model: model,
                fallbackTitle: surface.title,
                presentHistory: { isHistoryPresented = true },
                presentAgentPicker: { isAgentPickerPresented = true },
                startNewPrompt: {
                    model.clearComposer()
                    model.errorMessage = nil
                    shouldFocusComposer = true
                },
                presentInfo: { isInfoPresented = true }
            )

            if let error = model.errorMessage {
                ChatGPTConnectionBanner(message: error, refresh: model.refreshSessions)
            }

            ChatGPTAgentTimeline(model: model, sourceAvailable: source != nil)
            ChatGPTAgentComposer(model: model, focusRequested: $shouldFocusComposer)
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            model.start()
        }
        .sheet(isPresented: $isHistoryPresented) {
            ChatGPTHistorySheet(model: model) {
                isHistoryPresented = false
            }
        }
        .sheet(isPresented: $isAgentPickerPresented) {
            ChatGPTAgentPickerSheet(model: model) {
                isAgentPickerPresented = false
            }
        }
        .sheet(isPresented: $isInfoPresented) {
            ChatGPTAgentInfoSheet(session: model.selectedSession)
        }
        .accessibilityIdentifier("MobileAgentChatSurface-\(surface.id.rawValue)")
    }
}

private struct ChatGPTAgentTopBar: View {
    @Bindable var model: AgentChatViewModel
    let fallbackTitle: String
    let presentHistory: () -> Void
    let presentAgentPicker: () -> Void
    let startNewPrompt: () -> Void
    let presentInfo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: presentHistory) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.06), in: Circle())
            .accessibilityLabel("Conversation history")

            Button(action: presentAgentPicker) {
                HStack(spacing: 5) {
                    Image(systemName: model.selectedSession?.agentKind.chatSystemImage ?? "bubble.left.and.bubble.right")
                        .font(.subheadline.weight(.semibold))
                    Text(model.selectedSession?.agentKind.displayName ?? fallbackTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose coding agent")

            Button(action: startNewPrompt) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New prompt")

            Menu {
                Button("Refresh conversations", systemImage: "arrow.clockwise") {
                    model.refreshSessions()
                }
                Button("Conversation details", systemImage: "info.circle", action: presentInfo)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Conversation actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ChatGPTConnectionBanner: View {
    let message: String
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Retry", action: refresh)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

private struct ChatGPTAgentTimeline: View {
    @Bindable var model: AgentChatViewModel
    let sourceAvailable: Bool

    var body: some View {
        Group {
            if !sourceAvailable && model.sessions.isEmpty {
                ChatGPTUnavailableView()
            } else if model.sessions.isEmpty {
                ChatGPTEmptySessionsView(
                    isLoading: model.isLoadingSessions,
                    errorMessage: model.errorMessage,
                    refresh: model.refreshSessions
                )
            } else if let timeline = model.timeline {
                ChatGPTTranscriptScroll(timeline: timeline, model: model)
            } else {
                ProgressView("Loading conversation")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatGPTTranscriptScroll: View {
    let timeline: AgentChatTimelineState
    @Bindable var model: AgentChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if timeline.hasMoreHistory {
                        Button {
                            model.loadOlderHistory()
                        } label: {
                            HStack(spacing: 7) {
                                if timeline.isLoadingHistory {
                                    ProgressView().controlSize(.small)
                                }
                                Text("Show earlier messages")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(timeline.messages) { message in
                        ChatGPTMessageRow(
                            message: message,
                            isStreaming: false,
                            onAnswer: model.answer(optionIndex:),
                            onCopy: copy,
                            onRetry: retry
                        )
                        .id(message.id)
                    }

                    ForEach(timeline.terminalBlocks) { block in
                        ChatGPTTerminalBlock(block: block)
                            .id("terminal-\(block.id)")
                    }

                    if let streaming = timeline.streamingProse {
                        ChatGPTMessageRow(
                            message: streaming,
                            isStreaming: true,
                            onAnswer: model.answer(optionIndex:),
                            onCopy: copy,
                            onRetry: retry
                        )
                        .id("streaming-prose")
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 20)
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

    private func copy(_ message: ChatMessage) {
        guard let text = message.copyableText else { return }
        UIPasteboard.general.string = text
    }

    private func retry(_ message: ChatMessage) {
        guard case .prose(let prose) = message.kind else { return }
        model.composerText = prose.text
    }
}

private struct ChatGPTMessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onAnswer: (Int) -> Void
    let onCopy: (ChatMessage) -> Void
    let onRetry: (ChatMessage) -> Void

    var body: some View {
        switch message.role {
        case .user:
            ChatGPTUserMessage(message: message)
        case .agent:
            ChatGPTAssistantMessage(
                message: message,
                isStreaming: isStreaming,
                onAnswer: onAnswer,
                onCopy: onCopy,
                onRetry: onRetry
            )
        case .system:
            ChatGPTSystemMessage(message: message)
        }
    }
}

private struct ChatGPTUserMessage: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 42)
            VStack(alignment: .leading, spacing: 8) {
                ChatGPTMessageContent(message: message, onAnswer: { _ in })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(red: 0.84, green: 0.91, blue: 1.0), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentChatMessage-\(message.id)")
    }
}

private struct ChatGPTAssistantMessage: View {
    let message: ChatMessage
    let isStreaming: Bool
    let onAnswer: (Int) -> Void
    let onCopy: (ChatMessage) -> Void
    let onRetry: (ChatMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            ChatGPTMessageContent(message: message, onAnswer: onAnswer)
            if message.showsAssistantActions {
                ChatGPTMessageActions(
                    message: message,
                    onCopy: { onCopy(message) },
                    onRetry: { onRetry(message) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentChatMessage-\(message.id)")
    }
}

private struct ChatGPTSystemMessage: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: message.statusSystemImage)
            Text(message.statusText)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

private struct ChatGPTMessageContent: View {
    let message: ChatMessage
    let onAnswer: (Int) -> Void

    var body: some View {
        switch message.kind {
        case .prose(let prose):
            AgentFeedMarkdownText(markdown: prose.text, font: .body)
                .fixedSize(horizontal: false, vertical: true)
        case .thought(let thought):
            ChatGPTReasoningBlock(text: thought.text)
        case .toolUse(let tool):
            ChatGPTToolBlock(tool: tool)
        case .terminal(let terminal):
            ChatGPTTerminalCaptureBlock(terminal: terminal)
        case .fileEdit(let edit):
            ChatGPTFileEditBlock(edit: edit)
        case .permissionRequest(let permission):
            ChatGPTPermissionBlock(permission: permission, onAnswer: onAnswer)
        case .question(let question):
            ChatGPTQuestionBlock(question: question, onAnswer: onAnswer)
        case .status(let status):
            ChatGPTStatusBlock(status: status)
        case .attachment(let attachment):
            ChatGPTAttachmentBlock(attachment: attachment)
        case .unsupported(let payload):
            ChatGPTUnsupportedBlock(payload: payload)
        }
    }
}

private struct ChatGPTMessageActions: View {
    let message: ChatMessage
    let onCopy: () -> Void
    let onRetry: () -> Void
    @State private var feedback: Feedback?
    @State private var speechSynthesizer = AVSpeechSynthesizer()

    private enum Feedback: Equatable {
        case positive
        case negative
    }

    var body: some View {
        HStack(spacing: 17) {
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("Copy response")
            Button { speak() } label: { Image(systemName: "speaker.wave.2") }
                .accessibilityLabel("Read response aloud")
            Button { toggleFeedback(.positive) } label: {
                Image(systemName: feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
                .accessibilityLabel("Like response")
                .accessibilityValue(feedback == .positive ? "Selected" : "Not selected")
            Button { toggleFeedback(.negative) } label: {
                Image(systemName: feedback == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
                .accessibilityLabel("Dislike response")
                .accessibilityValue(feedback == .negative ? "Selected" : "Not selected")
            Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("Use response as a new prompt")
            if let text = message.copyableText {
                ShareLink(item: text) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share response")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }

    private func speak() {
        guard let text = message.copyableText else { return }
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(AVSpeechUtterance(string: text))
    }

    private func toggleFeedback(_ next: Feedback) {
        feedback = feedback == next ? nil : next
    }
}

private struct ChatGPTReasoningBlock: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            AgentFeedMarkdownText(markdown: text, font: .callout, color: .secondary)
                .padding(.top, 5)
        } label: {
            Label("Reasoning", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }
}

private struct ChatGPTToolBlock: View {
    let tool: ChatToolUse
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let input = tool.inputDetail, !input.isEmpty {
                    ChatGPTCodeBlock(text: input)
                }
                if let output = tool.output, !output.isEmpty {
                    ChatGPTCodeBlock(text: output)
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tool.status.chatSystemImage)
                    .foregroundStyle(tool.status == .failed ? .red : tool.status == .running ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.toolName).font(.subheadline.weight(.semibold))
                    Text(tool.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(tool.status.chatLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)) }
        .tint(.secondary)
    }
}

private struct ChatGPTTerminalCaptureBlock: View {
    let terminal: ChatTerminalCapture
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let output = terminal.output, !output.isEmpty {
                ChatGPTCodeBlock(text: output)
                    .padding(.top, 7)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: terminal.isRunning ? "terminal" : "checkmark.circle")
                    .foregroundStyle(terminal.isRunning ? .orange : .green)
                Text(terminal.command)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 3)
                if let code = terminal.exitCode {
                    Text("exit \(code)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .tint(.secondary)
    }
}

private struct ChatGPTFileEditBlock: View {
    let edit: ChatFileEdit
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let diff = edit.unifiedDiff, !diff.isEmpty {
                ChatGPTCodeBlock(text: diff)
                    .padding(.top, 7)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: edit.operation.chatSystemImage)
                    .foregroundStyle(edit.operation == .delete ? .red : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(edit.filePath).font(.callout.monospaced().weight(.semibold)).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(edit.operation.chatLabel)
                        if let additions = edit.additions { Text("+\(additions)").foregroundStyle(.green) }
                        if let deletions = edit.deletions { Text("-\(deletions)").foregroundStyle(.red) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .tint(.secondary)
    }
}

private struct ChatGPTTerminalBlock: View {
    let block: TerminalCommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: block.isInteractive ? "rectangle.on.rectangle" : "terminal")
                Text(block.command.isEmpty ? "Shell" : block.command)
                    .font(.callout.monospaced().weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 3)
                if let code = block.exitCode {
                    Text("exit \(code)").font(.caption.monospaced()).foregroundStyle(block.failed ? .red : .secondary)
                } else if block.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
            if !block.output.isEmpty { ChatGPTCodeBlock(text: block.output) }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ChatGPTPermissionBlock: View {
    let permission: ChatPermissionRequest
    let onAnswer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(permission.title, systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            ChatGPTCodeBlock(text: permission.subject)
            if let resolution = permission.resolution {
                Label(resolution.chatLabel, systemImage: "checkmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button("Allow") { onAnswer(0) }.buttonStyle(.borderedProminent)
                    Button("Deny") { onAnswer(1) }.buttonStyle(.bordered)
                }
            }
        }
        .padding(13)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ChatGPTQuestionBlock: View {
    let question: ChatQuestion
    let onAnswer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Question", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
            AgentFeedMarkdownText(markdown: question.prompt, font: .body)
            if let selected = question.selectedOptionLabel {
                Label("Selected: \(selected)", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button { onAnswer(index) } label: {
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
                        .padding(9)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(13)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ChatGPTStatusBlock: View {
    let status: ChatStatusTransition

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: status.event.chatSystemImage)
            Text(status.detail ?? status.event.chatLabel)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ChatGPTAttachmentBlock: View {
    let attachment: ChatAttachment

    var body: some View {
        Label(
            attachment.displayName ?? "Attachment",
            systemImage: attachment.media == .image ? "photo" : "doc"
        )
        .font(.body.weight(.medium))
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ChatGPTUnsupportedBlock: View {
    let payload: ChatUnsupportedPayload

    var body: some View {
        Label("Unsupported update · \(payload.rawType)", systemImage: "questionmark.diamond")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct ChatGPTCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
        }
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ChatGPTAgentComposer: View {
    @Bindable var model: AgentChatViewModel
    @Binding var focusRequested: Bool
    @FocusState private var isFocused: Bool
    @State private var dictation: ComposerDictationController
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var stagingTask: Task<Void, Never>?

    init(model: AgentChatViewModel, focusRequested: Binding<Bool>) {
        self.model = model
        _focusRequested = focusRequested
        _dictation = State(initialValue: ComposerDictationController())
    }

    var body: some View {
        VStack(spacing: 7) {
            if !model.pendingAttachments.isEmpty {
                ChatGPTDraftAttachmentRow(model: model)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Photos", systemImage: "photo") { isPhotoPickerPresented = true }
                    Button("Files", systemImage: "folder") { isFileImporterPresented = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add attachment")

                TextField("Message \(model.selectedSession?.agentKind.displayName ?? "agent")", text: $model.composerText, axis: .vertical)
                    .lineLimit(1...7)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .disabled(dictation.locksComposerField)
                    .onSubmit { send() }

                if !model.composerText.isEmpty || !model.pendingAttachments.isEmpty {
                    Button {
                        model.clearComposer()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear message")
                }

                Button(action: toggleDictation) {
                    Image(systemName: dictation.state.isListening ? "stop.fill" : "mic")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(dictation.state.isListening ? .red : .primary)
                .disabled(!dictation.isAvailable)
                .accessibilityLabel(dictation.state.isListening ? "Stop dictation" : "Dictate message")

                if model.canInterrupt {
                    Button { model.interrupt() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.black, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop agent")
                    .contextMenu {
                        Button("Hard interrupt", role: .destructive) { model.interrupt(hard: true) }
                    }
                } else {
                    Button(action: send) {
                        Group {
                            if model.isSending {
                                ProgressView().tint(.white).controlSize(.small)
                            } else if model.canSend {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                            } else {
                                Image(systemName: "waveform")
                                    .font(.system(size: 15, weight: .bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(model.canSend ? Color.accentColor : Color.blue, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canSend && !dictation.isAvailable)
                    .accessibilityLabel(model.canSend ? "Send message" : "Start voice input")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 10)
        .background(.bar)
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoPickerItems,
            maxSelectionCount: 8,
            matching: .images
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: stageFiles
        )
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            let selectedItems = items
            photoPickerItems = []
            stageTask { await stagePhotos(selectedItems) }
        }
        .onChange(of: focusRequested) { _, requested in
            guard requested else { return }
            isFocused = true
            focusRequested = false
        }
        .onDisappear {
            stagingTask?.cancel()
            dictation.cancel()
        }
    }

    private func send() {
        if model.canSend {
            dictation.cancel()
            model.send()
        } else if dictation.isAvailable {
            toggleDictation()
        }
    }

    private func toggleDictation() {
        dictation.toggle(existingText: model.composerText) { merged in
            model.composerText = merged
        }
    }

    private func stageTask(_ operation: @escaping @MainActor () async -> Void) {
        stagingTask?.cancel()
        stagingTask = Task { @MainActor in
            await operation()
        }
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard !Task.isCancelled else { return }
            do {
                guard let imported = try await ImportedPhotoLibraryFile.load(item), imported.kind == .image else { continue }
                defer { try? FileManager.default.removeItem(at: imported.url) }
                guard let prepared = await MobileImageAttachmentPreparer().prepare(url: imported.url) else { continue }
                model.addAttachment(
                    AgentChatDraftAttachment(
                        displayName: imported.originalFileName,
                        data: prepared.data,
                        format: prepared.format == "jpg" ? .jpeg : .png,
                        thumbnailData: prepared.thumbnailData
                    )
                )
            } catch {
                continue
            }
        }
    }

    private func stageFiles(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        stageTask {
            for url in urls {
                guard !Task.isCancelled else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let prepared = await MobileImageAttachmentPreparer().prepare(url: url) else { continue }
                model.addAttachment(
                    AgentChatDraftAttachment(
                        displayName: url.lastPathComponent,
                        data: prepared.data,
                        format: prepared.format == "jpg" ? .jpeg : .png,
                        thumbnailData: prepared.thumbnailData
                    )
                )
            }
        }
    }
}

private struct ChatGPTDraftAttachmentRow: View {
    @Bindable var model: AgentChatViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { attachment in
                    ChatGPTDraftAttachmentChip(
                        attachment: attachment,
                        remove: { model.removeAttachment(id: attachment.id) }
                    )
                }
            }
            .padding(.horizontal, 3)
        }
        .frame(height: 54)
    }
}

private struct ChatGPTDraftAttachmentChip: View {
    let attachment: AgentChatDraftAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let data = attachment.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipped()
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
    }
}

private struct ChatGPTHistorySheet: View {
    @Bindable var model: AgentChatViewModel
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    model.clearComposer()
                    dismiss()
                } label: {
                    Label("New prompt", systemImage: "square.and.pencil")
                }
                .foregroundStyle(.primary)

                Section("Conversations") {
                    ForEach(filteredSessions) { session in
                        Button {
                            model.select(session)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: session.agentKind.chatSystemImage)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title ?? session.agentKind.displayName)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(session.agentKind.displayName + " · " + session.state.chatLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if session.id == model.selectedSessionID {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button { model.refreshSessions() } label: {
                        Label("Refresh conversations", systemImage: "arrow.clockwise")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search conversations")
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: dismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var filteredSessions: [ChatSessionDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.sessions }
        return model.sessions.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(trimmed)
                || $0.agentKind.displayName.localizedCaseInsensitiveContains(trimmed)
                || ($0.workingDirectory ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }
}

private struct ChatGPTAgentPickerSheet: View {
    @Bindable var model: AgentChatViewModel
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Coding agents") {
                    ChatGPTAgentChoice(
                        title: "Codex",
                        detail: "OpenAI coding agent",
                        symbol: "chevron.left.forwardslash.chevron.right",
                        isSelected: model.selectedSession?.agentKind.sourceName == "codex",
                        action: { model.selectFirstSession(sourceName: "codex"); dismiss() }
                    )
                    ChatGPTAgentChoice(
                        title: "Claude Code",
                        detail: "Anthropic coding agent",
                        symbol: "sparkles",
                        isSelected: model.selectedSession?.agentKind.sourceName == "claude",
                        action: { model.selectFirstSession(sourceName: "claude"); dismiss() }
                    )
                    ChatGPTAgentChoice(
                        title: "OpenCode",
                        detail: "Open source coding agent",
                        symbol: "cube.transparent",
                        isSelected: model.selectedSession?.agentKind.isOpenCode == true,
                        action: { model.selectFirstSession(sourceName: "opencode"); dismiss() }
                    )
                }
            }
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done", action: dismiss) }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct ChatGPTAgentChoice: View {
    let title: String
    let detail: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 30)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

private struct ChatGPTAgentInfoSheet: View {
    let session: ChatSessionDescriptor?

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    LabeledContent("Provider", value: session?.agentKind.displayName ?? "Not selected")
                    LabeledContent("State", value: session?.state.chatLabel ?? "Idle")
                }
                Section("Workspace") {
                    LabeledContent("Directory", value: session?.workingDirectory ?? "Unknown")
                    LabeledContent("Terminal", value: session?.terminalID ?? "Unknown")
                }
            }
            .navigationTitle("Conversation details")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

private struct ChatGPTUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "Connect to your Mac",
            systemImage: "wifi.exclamationmark",
            description: Text("Reconnect to load your coding-agent conversations.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatGPTEmptySessionsView: View {
    let isLoading: Bool
    let errorMessage: String?
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(errorMessage ?? "No coding-agent conversations")
                    .font(.headline)
                Text("Start Codex, Claude Code, or OpenCode in this workspace, then refresh.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Button("Refresh conversations", action: refresh)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ChatAgentKind {
    var chatSystemImage: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .other(let source) where source.caseInsensitiveCompare("opencode") == .orderedSame: "cube.transparent"
        case .other: "cpu"
        }
    }
}

private extension ChatAgentState {
    var chatLabel: String {
        switch self {
        case .idle: "Ready"
        case .working: "Working"
        case .needsInput: "Needs your input"
        case .ended: "Ended"
        }
    }
}

private extension ChatToolUse.Status {
    var chatLabel: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        }
    }

    var chatSystemImage: String {
        switch self {
        case .running: "gearshape.2"
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.octagon"
        }
    }
}

private extension ChatFileEdit.Operation {
    var chatLabel: String {
        switch self {
        case .edit: "Edited"
        case .write: "Created"
        case .delete: "Deleted"
        }
    }

    var chatSystemImage: String {
        switch self {
        case .edit: "pencil"
        case .write: "doc.badge.plus"
        case .delete: "trash"
        }
    }
}

private extension ChatPermissionRequest.Resolution {
    var chatLabel: String {
        switch self {
        case .approved: "Allowed"
        case .denied: "Denied"
        case .expired: "Expired"
        }
    }
}

private extension ChatStatusTransition.Event {
    var chatLabel: String {
        switch self {
        case .sessionStarted: "Session started"
        case .sessionEnded: "Session ended"
        case .interrupted: "Interrupted"
        case .contextCompacted: "Context compacted"
        }
    }

    var chatSystemImage: String {
        switch self {
        case .sessionStarted: "play.circle"
        case .sessionEnded: "stop.circle"
        case .interrupted: "pause.circle"
        case .contextCompacted: "arrow.down.right.and.arrow.up.left"
        }
    }
}

private extension ChatMessage {
    var copyableText: String? {
        switch kind {
        case .prose(let prose): prose.text
        case .thought(let thought): thought.text
        case .unsupported(let payload): payload.rawType
        default: nil
        }
    }

    var showsAssistantActions: Bool {
        role == .agent && copyableText != nil
    }

    var statusText: String {
        if case .status(let status) = kind { return status.detail ?? status.event.chatLabel }
        return "Update"
    }

    var statusSystemImage: String {
        if case .status(let status) = kind { return status.event.chatSystemImage }
        return "info.circle"
    }
}

#endif
