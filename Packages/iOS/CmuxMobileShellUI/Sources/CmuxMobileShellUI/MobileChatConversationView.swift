import CmuxAgentChat
import SwiftUI

/// A focused transcript view with a native multiline composer.
struct MobileChatConversationView: View {
    let sessionID: String
    let model: MobileChatHomeModel
    let onBack: () -> Void

    @State private var composerText = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
                HStack(spacing: 6) {
                    MobileChatStateDot(state: sessionState)
                    Text(provider.title)
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(provider.title), \(sessionState.displayName)")
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

    private var provider: MobileChatProvider {
        MobileChatProvider.resolve(session?.agentKind ?? .other("opencode"))
    }

    private var sessionTitle: String {
        if let title = session?.title, !title.isEmpty { return title }
        return "New \(provider.title) chat"
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
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message your agent", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .accessibilityIdentifier("MobileChatComposer")
            if isWorking {
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
                        .background(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor, in: Circle())
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("MobileChatSend")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
        }
    }
}
