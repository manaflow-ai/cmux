#if DEBUG
import CmuxAgentChat
import CmuxAgentChatUI
import SwiftUI

/// Debug-only host for the plain-terminal chat log (#5). Feeds sample command
/// blocks as `.terminalCommand` rows through the real
/// ``CmuxAgentChatUI/ChatTranscriptListView`` so the single-column monospace
/// log is verified inside the actual transcript machinery (row dispatch,
/// scroll, expansion) before a Mac host parses real PTY streams.
struct TerminalLogDemoScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expandedIDs: Set<String> = []
    @State private var draft = ""

    private static let blocks: [TerminalCommandBlock] = [
        TerminalCommandBlock(
            id: 0,
            command: "ls -la",
            output: "total 24\ndrwxr-xr-x   6 me  staff   192 Jun 12 22:10 .\ndrwxr-xr-x  18 me  staff   576 Jun 12 21:55 ..\n-rw-r--r--   1 me  staff    42 Jun 12 22:10 README.md\n-rw-r--r--   1 me  staff  1024 Jun 12 22:10 main.swift",
            exitCode: 0,
            isRunning: false
        ),
        TerminalCommandBlock(
            id: 1,
            command: "git status",
            output: "On branch feat-ios-chat-ui\nnothing to commit, working tree clean",
            exitCode: 0,
            isRunning: false
        ),
        TerminalCommandBlock(
            id: 2,
            command: "swift build",
            output: (1...20).map { "Compiling module step \($0)" }.joined(separator: "\n"),
            exitCode: 0,
            isRunning: false
        ),
        TerminalCommandBlock(
            id: 3,
            command: "cat missing.txt",
            output: "cat: missing.txt: No such file or directory",
            exitCode: 1,
            isRunning: false
        ),
        TerminalCommandBlock(
            id: 4,
            command: "npm run dev",
            output: "Starting dev server…\nListening on http://localhost:3000",
            exitCode: nil,
            isRunning: true
        ),
        TerminalCommandBlock(
            id: 5,
            command: "vim notes.md",
            output: "",
            exitCode: nil,
            isRunning: true,
            isInteractive: true
        ),
    ]

    private var rows: [ChatTranscriptRow] {
        Self.blocks.map { ChatTranscriptRow.terminalCommand($0) }
    }

    var body: some View {
        NavigationStack {
            ChatTranscriptListView(
                rows: rows,
                expandedIDs: expandedIDs,
                agentState: .idle,
                hasMoreHistory: false,
                actions: actions,
                onReachTop: {}
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposerView(
                    agentState: .idle,
                    agentKind: .other("shell"),
                    isTerminal: true,
                    isConnected: true,
                    draft: $draft,
                    onSend: { _, _ in },
                    onInterrupt: { _ in },
                    onOpenTerminal: {}
                )
            }
            .navigationTitle("Terminal Log Demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("TerminalLogDemoDone")
                }
            }
        }
    }

    private var actions: ChatRowActions {
        ChatRowActions(
            toggleExpanded: { id in
                if expandedIDs.contains(id) {
                    expandedIDs.remove(id)
                } else {
                    expandedIDs.insert(id)
                }
            },
            answerOption: { _ in },
            retryPending: { _ in },
            discardPending: { _ in },
            openTerminal: {}
        )
    }
}
#endif
