#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Editing and execution stay explicit; opening a suggestion never sends input.
struct TerminalCommandReviewView: View {
    let suggestion: TerminalCommandSuggestion
    let run: @MainActor (TerminalCommandSuggestion, String) async -> Bool
    let completed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var sending = false
    @State private var failed = false
    @State private var sendTask: Task<Void, Never>?

    init(suggestion: TerminalCommandSuggestion,
         run: @escaping @MainActor (TerminalCommandSuggestion, String) async -> Bool,
         completed: @escaping () -> Void) {
        self.suggestion = suggestion
        self.run = run
        self.completed = completed
        _text = State(initialValue: suggestion.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("mobile.commands.reviewHint", defaultValue: "Edit the command, then tap Run to send it to this terminal."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                CommandTextEditor(text: $text, enabled: !sending)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if failed {
                    Text(L10n.string("mobile.commands.sendFailed", defaultValue: "Couldn’t run the command. Check the connection and reload Commands if the session changed. Your text is kept here."))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle(L10n.string("mobile.commands.reviewTitle", defaultValue: "Review Command"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.commands.cancel", defaultValue: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button(L10n.string("mobile.commands.run", defaultValue: "Run"), action: send)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("MobileTerminalCommandRun")
                    }
                }
            }
        }
        .onDisappear { sendTask?.cancel() }
    }

    private func send() {
        guard !sending else { return }
        let editedText = text
        sending = true
        failed = false
        sendTask = Task { @MainActor in
            let sent = await run(suggestion, editedText)
            guard !Task.isCancelled else { return }
            sending = false
            if sent { completed() } else { failed = true }
        }
    }
}
#endif
