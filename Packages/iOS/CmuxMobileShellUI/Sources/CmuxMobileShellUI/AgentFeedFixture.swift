#if os(iOS)
import CmuxAgentChat
import Foundation

/// Stable content used by CMUX Labs and UI previews. It deliberately includes
/// every wire primitive so a visual variant cannot hide an unsupported card.
enum AgentFeedFixture {
    static let referenceDate = Date(timeIntervalSince1970: 1_786_000_000)
    static let sessionID = "feed-lab-session"
    static let terminalID = "feed-lab-terminal"
    static let finishedSessionID = "feed-lab-finished-session"
    static let finishedTerminalID = "feed-lab-finished-terminal"

    static let descriptor = ChatSessionDescriptor(
        id: sessionID,
        agentKind: .codex,
        title: "Refactor the mobile shell",
        workspaceID: nil,
        terminalID: terminalID,
        workingDirectory: "cmux mobile",
        state: .needsInput(since: referenceDate.addingTimeInterval(600)),
        lastActivityAt: referenceDate.addingTimeInterval(720)
    )

    /// A second agent keeps the lab honest about the cross-agent timeline and
    /// gives the finished-turn state a real card beside the needs-input card.
    static let finishedDescriptor = ChatSessionDescriptor(
        id: finishedSessionID,
        agentKind: .claude,
        title: "Polish the release notes",
        workspaceID: nil,
        terminalID: finishedTerminalID,
        workingDirectory: "release desk",
        state: .idle,
        lastActivityAt: referenceDate.addingTimeInterval(1_080)
    )

    static let descriptors: [ChatSessionDescriptor] = [descriptor, finishedDescriptor]

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

    static let finishedMessages: [ChatMessage] = [
        message(
            1,
            role: .user,
            kind: .prose(ChatProse(text: "Tighten the release-note wording and check the final diff.")),
            sessionID: finishedSessionID
        ),
        message(
            2,
            role: .agent,
            kind: .prose(ChatProse(text: "The release notes are polished and the final diff is ready for your review.")),
            sessionID: finishedSessionID
        ),
        message(
            3,
            role: .agent,
            kind: .fileEdit(ChatFileEdit(
                filePath: "CHANGELOG.md",
                operation: .edit,
                additions: 6,
                deletions: 2,
                unifiedDiff: "@@ -1,2 +1,6 @@\n+## Next\n+\n+- Feed variants documented"
            )),
            sessionID: finishedSessionID
        ),
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

    static let messagesBySessionID: [String: [ChatMessage]] = [
        sessionID: messages,
        finishedSessionID: finishedMessages,
    ]

    static let terminalBlocksBySessionID: [String: [TerminalCommandBlock]] = [
        sessionID: terminalBlocks,
    ]

    static let workspaceNames: [String: String] = [:]

    private static func message(
        _ seq: Int,
        role: ChatRole,
        kind: ChatMessageKind,
        sessionID: String = Self.sessionID
    ) -> ChatMessage {
        ChatMessage(
            id: "\(sessionID)-\(seq)",
            seq: seq,
            role: role,
            timestamp: referenceDate.addingTimeInterval(Double(seq) * 60),
            kind: kind
        )
    }
}
#endif
