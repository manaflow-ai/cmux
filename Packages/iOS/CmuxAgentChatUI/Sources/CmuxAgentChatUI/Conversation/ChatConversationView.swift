import CmuxAgentChat
import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A native conversation surface with iMessage-style bubbles and Telegram-style
/// composer behavior. The view renders only provider-neutral chat values.
public struct ChatConversationView: View {
    @Bindable private var store: ChatConversationStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool
    @State private var draft = ""
    @State private var isAtBottom = true
    @State private var didAutoScroll = false
    @State private var prependAnchorID: String?

    private let bottomID = "chat-bottom-anchor"

    public init(store: ChatConversationStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollViewReader { scrollProxy in
                    ZStack(alignment: .bottomTrailing) {
                        transcript(scrollProxy: scrollProxy)

                        if !isAtBottom, !store.visibleMessages.isEmpty {
                            jumpToLatestButton(scrollProxy: scrollProxy)
                                .padding(.trailing, 16)
                                .padding(.bottom, 16)
                        }
                    }
                    .coordinateSpace(name: "chat-scroll")
                    .onPreferenceChange(ChatBottomMarkerPreference.self) { bottom in
                        isAtBottom = bottom <= viewport.size.height + 24
                    }
                    .onChange(of: store.renderRevision) { _, _ in
                        if let prependAnchorID {
                            self.prependAnchorID = nil
                            Task { @MainActor in
                                await Task.yield()
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    scrollProxy.scrollTo(prependAnchorID, anchor: .top)
                                }
                            }
                            return
                        }
                        guard isAtBottom else { return }
                        scrollToBottom(scrollProxy, animated: didAutoScroll)
                        didAutoScroll = true
                    }
                    .onChange(of: store.selectedSessionID) { _, _ in
                        isAtBottom = true
                        didAutoScroll = false
                        prependAnchorID = nil
                    }
                    .onAppear {
                        scrollToBottom(scrollProxy, animated: false)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
            .background(chatGroupedBackground)
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(String(localized: "chat.conversation.close", defaultValue: "Close", bundle: .module))
                }
                ToolbarItem(placement: .principal) {
                    sessionPicker
                }
                ToolbarItem(placement: .topBarTrailing) {
                    connectionIndicator
                }
            }
            #endif
            .task {
                store.start()
            }
            .onDisappear {
                store.stop()
            }
        }
    }

    private var navigationTitle: String {
        guard let selected = store.sessions.first(where: { $0.id == store.selectedSessionID }) else {
            return String(localized: "chat.conversation.title", defaultValue: "Chat", bundle: .module)
        }
        return selected.title?.isEmpty == false
            ? selected.title!
            : String(localized: "chat.conversation.title", defaultValue: "Chat", bundle: .module)
    }

    private var sessionPicker: some View {
        Menu {
            if store.sessions.isEmpty {
                Text(String(localized: "chat.conversation.no_sessions", defaultValue: "No conversations", bundle: .module))
            } else {
                ForEach(store.sessions) { session in
                    Button {
                        store.select(sessionID: session.id)
                    } label: {
                        Label {
                            Text(session.title ?? String(session.id.prefix(8)))
                        } icon: {
                            Image(systemName: sessionIcon(for: session.state))
                        }
                    }
                }
            }
            Divider()
            Button {
                store.createSession()
            } label: {
                Label(
                    String(localized: "chat.conversation.new", defaultValue: "New conversation", bundle: .module),
                    systemImage: "plus"
                )
            }
        } label: {
            VStack(spacing: 1) {
                Text(navigationTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 210)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ChatSessionPicker")
    }

    private var connectionIndicator: some View {
        Group {
            switch store.connectionState {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .connected:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .idle:
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(statusLabel)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .accessibilityIdentifier("ChatErrorMessage")
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    String(localized: "chat.conversation.composer.placeholder", defaultValue: "Message", bundle: .module),
                    text: $draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .submitLabel(.send)
                .focused($composerFocused)
                .onSubmit(sendDraft)
                .accessibilityIdentifier("ChatComposer")

                if store.isWorking {
                    Button {
                        store.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .accessibilityLabel(String(localized: "chat.conversation.stop", defaultValue: "Stop", bundle: .module))
                    .accessibilityIdentifier("ChatStopButton")
                }

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .disabled(!canSend)
                .accessibilityLabel(String(localized: "chat.conversation.send", defaultValue: "Send", bundle: .module))
                .accessibilityIdentifier("ChatSendButton")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy(duration: 0.2), value: store.isWorking)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.selectedSessionID != nil
            && !store.isSending
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        store.send(text: text)
        composerFocused = true
    }

    @ViewBuilder
    private func transcript(scrollProxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .center, spacing: 10) {
                if store.isLoadingOlder {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                }

                ForEach(store.visibleMessages) { message in
                    ChatConversationMessageRow(
                        message: message,
                        answer: { index in store.answer(optionIndex: index) }
                    )
                    .id(message.id)
                    .onAppear {
                        if message.id == store.visibleMessages.first?.id,
                           store.hasMoreHistory,
                           !store.isLoadingOlder,
                           prependAnchorID == nil {
                            prependAnchorID = message.id
                            store.loadOlder()
                        }
                    }
                }

                Color.clear
                    .frame(height: 1)
                    .id(bottomID)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ChatBottomMarkerPreference.self,
                                value: proxy.frame(in: .named("chat-scroll")).maxY
                            )
                        }
                    }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .overlay {
            if store.visibleMessages.isEmpty, store.connectionState == .connected {
                ContentUnavailableView(
                    String(localized: "chat.conversation.empty.title", defaultValue: "Start a conversation", bundle: .module),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(String(localized: "chat.conversation.empty.message", defaultValue: "Send a message to get started.", bundle: .module))
                )
                .padding(.bottom, 48)
            } else if case .failed = store.connectionState, store.visibleMessages.isEmpty {
                ContentUnavailableView(
                    String(localized: "chat.conversation.unavailable.title", defaultValue: "Chat unavailable", bundle: .module),
                    systemImage: "wifi.exclamationmark",
                    description: Text(store.errorMessage ?? String(localized: "chat.conversation.unavailable.message", defaultValue: "Reconnect to try again.", bundle: .module))
                )
                .padding(.horizontal, 28)
            }
        }
    }

    private func jumpToLatestButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(scrollProxy, animated: true)
            isAtBottom = true
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .accessibilityLabel(String(localized: "chat.conversation.jump_latest", defaultValue: "Jump to latest", bundle: .module))
        .accessibilityIdentifier("ChatJumpToLatestButton")
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        Task { @MainActor in
            await Task.yield()
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private var statusLabel: String {
        switch store.connectionState {
        case .idle: return String(localized: "chat.conversation.status.idle", defaultValue: "Offline", bundle: .module)
        case .loading: return String(localized: "chat.conversation.status.loading", defaultValue: "Connecting", bundle: .module)
        case .connected:
            if store.isWorking { return String(localized: "chat.conversation.status.working", defaultValue: "Working", bundle: .module) }
            return String(localized: "chat.conversation.status.ready", defaultValue: "Ready", bundle: .module)
        case .failed: return String(localized: "chat.conversation.status.failed", defaultValue: "Unavailable", bundle: .module)
        }
    }

    private var chatGroupedBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.secondary.opacity(0.08)
        #endif
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .connected: return store.isWorking ? .orange : .green
        case .loading: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private func sessionIcon(for state: ChatAgentState) -> String {
        switch state {
        case .needsInput: return "questionmark.circle"
        case .working: return "circle.dotted"
        case .idle: return "circle"
        case .ended: return "checkmark.circle"
        }
    }
}

private struct ChatBottomMarkerPreference: PreferenceKey {
    static let defaultValue = CGFloat.greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatConversationMessageRow: View {
    let message: ChatMessage
    let answer: (Int) -> Void

    var body: some View {
        switch message.kind {
        case .prose(let prose):
            bubble {
                ChatConversationMarkdownText(text: prose.text)
            }
        case .thought(let thought):
            compactCard(title: String(localized: "chat.conversation.thought", defaultValue: "Thought", bundle: .module), icon: "brain") {
                Text(thought.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .toolUse(let tool):
            compactCard(title: tool.toolName, icon: "wrench.and.screwdriver") {
                Text(tool.summary)
                    .font(.subheadline)
                if let output = tool.output, !output.isEmpty {
                    Text(output)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .terminal(let terminal):
            compactCard(
                title: terminal.isRunning
                    ? String(localized: "chat.conversation.running", defaultValue: "Running", bundle: .module)
                    : String(localized: "chat.conversation.terminal", defaultValue: "Terminal", bundle: .module),
                icon: "terminal"
            ) {
                Text(terminal.command)
                    .font(.caption.monospaced())
                if let output = terminal.output, !output.isEmpty {
                    Text(output)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .fileEdit(let edit):
            compactCard(title: edit.filePath, icon: "doc.badge.gearshape") {
                Text(edit.operation.rawValue.capitalized)
                    .font(.subheadline)
                if let diff = edit.unifiedDiff {
                    Text(diff)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        case .permissionRequest(let request):
            permissionCard(request, answer: answer)
        case .question(let question):
            questionCard(question, answer: answer)
        case .status(let status):
            statusRow(status)
        case .attachment(let attachment):
            compactCard(
                title: attachment.displayName ?? String(localized: "chat.conversation.attachment", defaultValue: "Attachment", bundle: .module),
                icon: "paperclip"
            ) {
                Text(attachment.media.rawValue.capitalized)
                    .font(.subheadline)
            }
        case .unsupported(let payload):
            compactCard(
                title: String(localized: "chat.conversation.unsupported", defaultValue: "Unsupported message", bundle: .module),
                icon: "questionmark.square"
            ) {
                Text(payload.rawType)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func bubble<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .user { Spacer(minLength: 28) }
            content()
                .frame(maxWidth: 320, alignment: .leading)
                .foregroundStyle(message.role == .user ? .white : .primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu {
                    Button(String(localized: "chat.conversation.copy", defaultValue: "Copy", bundle: .module)) { copy(messageText) }
                }
            if message.role != .user { Spacer(minLength: 28) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ChatMessage-\(message.id)")
    }

    @ViewBuilder
    private func compactCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button(String(localized: "chat.conversation.copy", defaultValue: "Copy", bundle: .module)) { copy(messageText) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ChatMessage-\(message.id)")
    }

    private func permissionCard(_ request: ChatPermissionRequest, answer: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "hand.raised")
                .font(.subheadline.weight(.semibold))
            Text(request.subject)
                .font(.subheadline)
                .textSelection(.enabled)
            if let resolution = request.resolution {
                Text(resolution.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resolution == .approved ? .green : .secondary)
            } else if request.options.isEmpty {
                Text(String(localized: "chat.conversation.respond_in_composer", defaultValue: "Respond in the composer", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(request.options) { option in
                    Button(option.label) { answer(option.index) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ChatPermission-\(message.id)")
    }

    private func questionCard(_ question: ChatQuestion, answer: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.prompt)
                .font(.subheadline.weight(.semibold))
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    answer(index)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let detail = option.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("ChatQuestion-\(message.id)")
    }

    private func statusRow(_ status: ChatStatusTransition) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text(status.detail ?? status.event.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var messageText: String {
        switch message.kind {
        case .prose(let value): return value.text
        case .thought(let value): return value.text
        case .toolUse(let value): return [value.summary, value.output].compactMap { $0 }.joined(separator: "\n")
        case .terminal(let value): return [value.command, value.output].compactMap { $0 }.joined(separator: "\n")
        case .fileEdit(let value): return [value.filePath, value.unifiedDiff].compactMap { $0 }.joined(separator: "\n")
        case .permissionRequest(let value): return [value.title, value.subject].joined(separator: "\n")
        case .question(let value): return value.prompt
        case .status(let value): return value.detail ?? value.event.rawValue
        case .attachment(let value): return value.displayName ?? value.media.rawValue
        case .unsupported(let value): return value.rawType
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

private struct ChatConversationMarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: text) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}
