#if os(iOS)
import CmuxAgentChat
import Foundation

/// Stable content used by CMUX Labs and UI previews. It deliberately includes
/// every wire primitive so a visual variant cannot hide an unsupported card.
enum AgentFeedFixture {
    static let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)
    static let sessionID = "feed-lab-session"
    static let workspaceID = "feed-lab-workspace"
    static let terminalID = "feed-lab-terminal"

    static let descriptor = ChatSessionDescriptor(
        id: sessionID,
        agentKind: .codex,
        title: "Refactor the mobile shell",
        workspaceID: workspaceID,
        terminalID: terminalID,
        workingDirectory: "/Users/aziz/cmux",
        state: .needsInput(since: referenceDate.addingTimeInterval(600)),
        lastActivityAt: referenceDate.addingTimeInterval(720)
    )

    static let messages: [ChatMessage] = [
        message(1, role: .user, kind: .prose(ChatProse(text: "Can you make the Feed feel like a first-class coding surface?"))),
        message(2, role: .agent, kind: .thought(ChatThought(text: "I am mapping each tool result to an actionable card."))),
        message(3, role: .agent, kind: .prose(ChatProse(text: "I found five interaction primitives to keep inline: commands, diffs, questions, permissions, and artifacts."))),
        message(4, role: .agent, kind: .toolUse(ChatToolUse(
            toolName: "Search",
            summary: "Search Packages/iOS for notification routing",
            inputDetail: "pattern: MobilePrimaryTab",
            output: "12 matches across the mobile shell",
            status: .succeeded,
            referencedPaths: ["Packages/iOS/CmuxMobileShellUI"]
        ))),
        message(5, role: .agent, kind: .terminal(ChatTerminalCapture(
            command: "swift test --package-path Packages/iOS/CmuxMobileShellUI",
            output: "Test Suite passed\n42 tests, 0 failures",
            exitCode: 0,
            durationSeconds: 18.4
        ))),
        message(6, role: .agent, kind: .fileEdit(ChatFileEdit(
            filePath: "WorkspaceShellView.swift",
            operation: .edit,
            additions: 38,
            deletions: 9,
            unifiedDiff: "@@ -240,6 +240,35 @@\n+ Feed tab content\n"
        ))),
        message(7, role: .agent, kind: .permissionRequest(ChatPermissionRequest(
            title: "Codex wants to run this command",
            subject: "git diff --stat",
            resolution: nil
        ))),
        message(8, role: .agent, kind: .question(ChatQuestion(
            prompt: "Which Feed composition should be the default?",
            options: [
                .init(label: "Orbit", detail: "Quiet and spacious"),
                .init(label: "Command Deck", detail: "Dense and fast")
            ],
            questionID: "feed-style"
        ))),
        message(9, role: .system, kind: .status(ChatStatusTransition(
            event: .contextCompacted,
            detail: "Context window compacted"
        ))),
        message(10, role: .user, kind: .attachment(ChatAttachment(
            media: .image,
            displayName: "feed-wireframe.png",
            hostPath: "/tmp/feed-wireframe.png"
        ))),
        message(11, role: .agent, kind: .unsupported(ChatUnsupportedPayload(rawType: "future_artifact")))
    ]

    static let terminalBlocks: [TerminalCommandBlock] = [
        TerminalCommandBlock(
            id: 1,
            command: "git status --short",
            output: " M WorkspaceShellView.swift",
            exitCode: 0,
            isRunning: false
        )
    ]

    static func entries() -> [AgentFeedEntry] {
        let messageEntries = messages.map { message in
            AgentFeedEntry(
                id: "fixture-\(message.id)",
                sessionID: sessionID,
                workspaceID: workspaceID,
                workspaceName: "cmux mobile",
                terminalID: terminalID,
                agentName: descriptor.agentKind.displayName,
                sessionTitle: descriptor.title,
                timestamp: message.timestamp,
                state: descriptor.state,
                content: .message(message),
                requiresReply: message.id == "fixture-7" || message.id == "fixture-8",
                isStreaming: false
            )
        }
        let terminalEntries = terminalBlocks.map { block in
            AgentFeedEntry(
                id: "fixture-terminal-\(block.id)",
                sessionID: sessionID,
                workspaceID: workspaceID,
                workspaceName: "cmux mobile",
                terminalID: terminalID,
                agentName: "Shell",
                sessionTitle: "Terminal command log",
                timestamp: referenceDate.addingTimeInterval(900),
                state: .idle,
                content: .terminalBlock(block),
                requiresReply: false,
                isStreaming: false
            )
        }
        return messageEntries + terminalEntries
    }

    private static func message(
        _ seq: Int,
        role: ChatRole,
        kind: ChatMessageKind
    ) -> ChatMessage {
        ChatMessage(
            id: "fixture-\(seq)",
            seq: seq,
            role: role,
            timestamp: referenceDate.addingTimeInterval(Double(seq) * 60),
            kind: kind
        )
    }
}
#endif
