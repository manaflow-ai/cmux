#if DEBUG
import CmuxAgentChat
import CmuxAgentChatUI
import SwiftUI

/// Debug-only host for the plain-terminal chat (#5). Drives the real
/// ``CmuxAgentChatUI/ChatScreen`` with a terminal-kind descriptor and a
/// ``CmuxAgentChat/FixtureChatEventSource`` serving command blocks, so the
/// full path (store history -> .terminalCommand rows -> log + terminal
/// composer + header) is verifiable on a simulator before a Mac host parses
/// real PTY streams.
struct TerminalLogDemoScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stack: DemoStack?
    @State private var draft = ""

    private static let blocks: [TerminalCommandBlock] = [
        TerminalCommandBlock(
            id: 0, command: "ls -la",
            output: [
                "total 96",
                "drwxr-xr-x   8 me  staff   256 Jun 12 22:10 .",
                "-rw-r--r--   1 me  staff    42 Jun 12 22:10 README.md",
                "-rw-r--r--   1 me  staff  1024 Jun 12 22:10 main.swift",
                "-rw-r--r--   1 me  staff   512 Jun 12 22:10 Package.swift",
                "-rw-r--r--   1 me  staff   256 Jun 12 22:10 Tests.swift",
                "drwxr-xr-x   4 me  staff   128 Jun 12 22:10 Sources",
                "drwxr-xr-x   4 me  staff   128 Jun 12 22:10 Fixtures",
            ].joined(separator: "\n"),
            exitCode: 0, isRunning: false
        ),
        TerminalCommandBlock(
            id: 1, command: "git status",
            output: """
            On branch feat-ios-chat-ui
            Your branch is up to date with 'origin/feat-ios-chat-ui'.

            Changes to be committed:
              modified: Sources/Transcript/TerminalLogDemoScreen.swift

            Untracked files:
              tmp/scroll-proof-before.png
              tmp/scroll-proof-after.png

            nothing else to commit
            """,
            exitCode: 0, isRunning: false
        ),
        TerminalCommandBlock(
            id: 2, command: "swift build",
            output: (1...20).map { "Compiling module step \($0)" }.joined(separator: "\n"),
            exitCode: 0, isRunning: false
        ),
        TerminalCommandBlock(
            id: 3, command: "cat missing.txt",
            output: [
                "cat: missing.txt: No such file or directory",
                "searched: ./missing.txt",
                "searched: ./Fixtures/missing.txt",
                "searched: ./Tests/missing.txt",
                "hint: regenerate fixtures before rerunning",
            ].joined(separator: "\n"),
            exitCode: 1, isRunning: false
        ),
        TerminalCommandBlock(
            id: 4, command: "npm run dev",
            output: """
            Starting dev server...
            Ready in 612ms
            Route / warmed in 91ms
            Route /handler/sign-in warmed in 87ms
            Route /handler/after-sign-in warmed in 82ms
            Listening on http://localhost:3000
            """,
            exitCode: nil, isRunning: true
        ),
        TerminalCommandBlock(
            id: 5, command: "vim notes.md",
            output: "", exitCode: nil, isRunning: true, isInteractive: true
        ),
    ] + (6...12).map { index in
        TerminalCommandBlock(
            id: index,
            command: "script/check-\(index).sh",
            output: (1...(index == 10 ? 24 : 8)).map { "check \(index).\($0): ok" }.joined(separator: "\n"),
            exitCode: 0,
            isRunning: false
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let stack {
                    ChatScreen(store: stack.store, draft: $draft, onOpenTerminal: {})
                } else {
                    ProgressView()
                        .task {
                            let descriptor = ChatSessionDescriptor(
                                id: "demo-terminal",
                                agentKind: .other("shell"),
                                kind: .terminal,
                                title: "~/project — zsh"
                            )
                            let source = FixtureChatEventSource(terminalBacklog: Self.blocks)
                            stack = DemoStack(
                                store: ChatConversationStore(descriptor: descriptor, source: source)
                            )
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("TerminalLogDemoDone")
                }
            }
        }
    }

    /// Holds the demo's store so its identity is stable across re-renders.
    private struct DemoStack {
        let store: ChatConversationStore
    }
}
#endif
