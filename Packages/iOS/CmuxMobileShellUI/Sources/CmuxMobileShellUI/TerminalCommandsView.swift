#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Suggestions are copied from original messages, never reconstructed from rendered rows.
struct TerminalCommandsView: View {
    let load: @MainActor () async throws -> [TerminalCommandSuggestion]
    let copy: (String) -> Void
    let review: (TerminalCommandSuggestion) -> Void

    @State private var commands: [TerminalCommandSuggestion]?
    @State private var failed = false
    @State private var attempt = 0
    @State private var copiedID: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let commands {
                    if commands.isEmpty {
                        Text(L10n.string("mobile.commands.empty", defaultValue: "No suggested ! commands found for this terminal."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(commands) { command in
                        commandRow(command)
                    }
                    Button(L10n.string("mobile.commands.refresh", defaultValue: "Refresh")) { attempt += 1 }
                } else if failed {
                    Text(L10n.string("mobile.commands.unavailable", defaultValue: "Original commands aren’t available for this terminal. You can still copy from Text."))
                        .foregroundStyle(.secondary)
                    Button(L10n.string("mobile.commands.retry", defaultValue: "Try Again")) { attempt += 1 }
                } else {
                    ProgressView(L10n.string("mobile.commands.loading", defaultValue: "Loading commands…"))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .accessibilityIdentifier("MobileTerminalCommands")
        .task(id: attempt) {
            failed = false
            commands = nil
            do {
                let loaded = try await load()
                try Task.checkCancellation()
                commands = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    private func commandRow(_ command: TerminalCommandSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(command.text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Button { copy(command.text) } label: {
                    Label(L10n.string("mobile.commands.copy", defaultValue: "Copy"), systemImage: "doc.on.doc")
                }
                Button { review(command) } label: {
                    Label(L10n.string("mobile.commands.reviewRun", defaultValue: "Review & Run"), systemImage: "terminal")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
