#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// What a chat's workspace tab does with the chat beyond the chat itself, set by the tab's
/// owner (a pushed chat outside a workspace has none): `/fork` and Edit and Resend of an
/// earlier prompt open their copy as a new tab next to it, as the Mac does.
public struct AgentChatTabActions {
    /// Fork Conversation to New Tab: the whole chat, copied into a new tab that comes to the front.
    public var fork: @MainActor () async -> Void
    /// Edit and Resend of an earlier prompt: a copy of the chat through the turn `throughSeq`
    /// ends (acpmux `acp.session.fork`) opens as a new tab and gets `prompt`; the chat stays as
    /// it is. False when the copy wasn't made (the tab owner said why).
    public var editAndResend: @MainActor (_ throughSeq: Int, _ prompt: String) async -> Bool

    public init(fork: @escaping @MainActor () async -> Void,
                editAndResend: @escaping @MainActor (_ throughSeq: Int, _ prompt: String) async -> Bool) {
        self.fork = fork
        self.editAndResend = editAndResend
    }
}

/// An earlier prompt being edited (its sheet's item).
struct EarlierPromptEdit: Identifiable, Hashable {
    let turnID: String
    let throughSeq: Int
    let original: String
    var id: String { turnID }
}

/// Edit and Resend of an earlier prompt: the prompt in an editor; Send forks the chat
/// before it into a new tab, which gets the edited text.
struct EarlierPromptEditSheet: View {
    let edit: EarlierPromptEdit
    let actions: AgentChatTabActions
    @State private var text: String
    @State private var sending = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(edit: EarlierPromptEdit, actions: AgentChatTabActions) {
        self.edit = edit
        self.actions = actions
        _text = State(initialValue: edit.original)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(minHeight: 160)
                        // Prompts are code-like: no autocorrect, no capitals (full verify D5).
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .accessibilityLabel("Message")
                        .accessibilityIdentifier("chat.editEarlier.field")
                } footer: {
                    Text("Sends in a new tab with a copy of this chat up to this message. This chat stays as it is.")
                }
            }
            .navigationTitle("Edit Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "arrow.up") { send() }
                        .disabled(trimmed.isEmpty || trimmed == edit.original.trimmingCharacters(in: .whitespacesAndNewlines) || sending)
                        .accessibilityIdentifier("chat.editEarlier.send")
                }
            }
            .overlay {
                if sending { ProgressView().controlSize(.large) }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(sending)
        .onAppear { focused = true }
    }

    private func send() {
        let prompt = trimmed
        sending = true
        Task { @MainActor in
            let sent = await actions.editAndResend(edit.throughSeq, prompt)
            sending = false
            if sent { dismiss() }
        }
    }
}

/// `/status`: the chat's session status, as the Mac's Session status card shows it. Each
/// value copies on a tap; Copy All copies every line.
struct SessionStatusSheet: View {
    let store: AgentChatStore
    @State private var load: Load = .loading
    @State private var copied: String?
    @Environment(\.dismiss) private var dismiss

    enum Load: Equatable {
        case loading
        case loaded(AgentSessionStatus)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch load {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Status is unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await read() } }
                    }
                case .loaded(let status):
                    List {
                        Section(status.harness) {
                            ForEach(status.fields) { field in
                                Button {
                                    UIPasteboard.general.string = field.value
                                    copied = field.label
                                } label: {
                                    LabeledContent(field.label) {
                                        Text(copied == field.label ? String(localized: "Copied") : field.value)
                                            .multilineTextAlignment(.trailing)
                                            .lineLimit(3)
                                            .textSelection(.enabled)
                                    }
                                }
                                .tint(.primary)
                                .accessibilityLabel(Text("\(field.label), \(field.value)"))
                                .accessibilityHint("Copies the value")
                                .accessibilityIdentifier("chat.status.\(field.label)")
                            }
                        }
                    }
                    .sensoryFeedback(.success, trigger: copied)
                }
            }
            .navigationTitle("Session Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                if case .loaded(let status) = load {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy All", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = status.copyText
                            copied = ""
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await read() }
    }

    private func read() async {
        load = .loading
        do {
            load = .loaded(try await store.source.sessionStatus())
        } catch {
            load = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}
#endif
