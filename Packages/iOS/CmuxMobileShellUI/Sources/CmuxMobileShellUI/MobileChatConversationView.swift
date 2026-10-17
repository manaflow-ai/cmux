import CmuxAgentChat
import SwiftUI

/// A focused transcript view with a native multiline composer.
struct MobileChatConversationView: View {
    let sessionID: String
    let model: MobileChatHomeModel
    let onBack: () -> Void
    let onMenu: () -> Void

    @State private var composerText = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let session {
                        MobileChatConversationContext(
                            provider: provider,
                            workingDirectory: session.workingDirectory,
                            state: sessionState
                        )
                    }
                    if model.loadingSessionIDs.contains(sessionID) && model.messages(for: sessionID).isEmpty {
                        ProgressView("Loading conversation…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                    }
                    ForEach(model.messages(for: sessionID)) { message in
                        MobileChatMessageRow(message: message) { optionIndex in
                            Task { await model.answer(optionIndex: optionIndex, in: sessionID) }
                        }
                        .id(message.id)
                    }
                    if model.messages(for: sessionID).isEmpty,
                       !model.loadingSessionIDs.contains(sessionID) {
                        Text("Send a message to get started.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages(for: sessionID).last?.id) { _, messageID in
                guard let messageID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(messageID, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MobileChatComposer(
                text: $composerText,
                isFocused: $composerFocused,
                isWorking: isWorking,
                providerTitle: provider?.title ?? "your agent",
                onSend: send,
                onStop: {
                    Task { await model.interrupt(sessionID: sessionID) }
                }
            )
        }
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Back to chats")
                .accessibilityIdentifier("MobileChatBackToChats")
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    if let provider {
                        MobileChatProviderBadge(provider: provider, size: 26)
                        Text(provider.title)
                            .font(.subheadline.weight(.semibold))
                    }
                    Menu {
                        Button("Copy conversation", systemImage: "doc.on.doc") { }
                        Button("Choose computer", systemImage: "desktopcomputer") { onMenu() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(provider.map { "\($0.title), \(sessionState.displayName)" } ?? "Chat")
            }
        }
        .task(id: sessionID) {
            model.open(sessionID: sessionID)
        }
        .onDisappear {
            model.close(sessionID: sessionID)
        }
    }

    private var session: ChatSessionDescriptor? {
        model.sessions.first { $0.id == sessionID }
    }

    private var provider: MobileChatProvider? {
        session.flatMap { MobileChatProvider.resolve($0.agentKind) }
    }

    private var sessionTitle: String {
        if let title = session?.title, !title.isEmpty { return title }
        return provider.map { "New \($0.title) chat" } ?? "Chat"
    }

    private var sessionState: ChatAgentState {
        session?.state ?? .idle
    }

    private var isWorking: Bool {
        if case .working = sessionState { return true }
        return false
    }

    private func send() {
        let text = composerText
        composerText = ""
        composerFocused = false
        Task { await model.send(text, to: sessionID) }
    }
}

private struct MobileChatComposer: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let isWorking: Bool
    let providerTitle: String
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            Menu {
                Button("Attach a file", systemImage: "paperclip") { }
                    .disabled(true)
                Button("Open computer", systemImage: "desktopcomputer") { }
                    .disabled(true)
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Add attachment")
            .accessibilityIdentifier("MobileChatAdd")
            TextField("Message \(providerTitle)", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .frame(minHeight: 30)
                .accessibilityLabel("Message \(providerTitle)")
                .accessibilityIdentifier("MobileChatComposer")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking {
                Button(action: {}) {
                    Image(systemName: "mic.fill")
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.secondary)
                }
                .disabled(true)
                .accessibilityLabel("Voice input unavailable")
            } else if isWorking {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.white)
                        .background(.red, in: Circle())
                }
                .accessibilityLabel("Stop agent")
                .accessibilityIdentifier("MobileChatStop")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.bold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Circle())
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("MobileChatSend")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.65), lineWidth: 0.7))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MobileChatConversationContext: View {
    let provider: MobileChatProvider?
    let workingDirectory: String?
    let state: ChatAgentState

    var body: some View {
        HStack(spacing: 8) {
            if let provider {
                MobileChatProviderBadge(provider: provider, size: 24)
            }
            if let workingDirectory, !workingDirectory.isEmpty {
                Text(workingDirectory)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Remote coding session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            MobileChatStateDot(state: state)
            Text(state.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .accessibilityIdentifier("MobileChatConversationContext")
    }
}
