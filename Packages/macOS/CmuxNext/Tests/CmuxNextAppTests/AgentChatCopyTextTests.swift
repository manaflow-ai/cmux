@testable import CmuxNextAgentPane
import Foundation
import Testing

@Suite struct AgentChatCopyTextTests {
    @Test @MainActor func copyNameActionWritesTheAcpmuxName() async {
        let outcome = await AgentChatCopyOperations.name(info: { ["name": "sr2/nx-settings"] }, isCurrent: { true })
        #expect(Self.copiedText(outcome) == "sr2/nx-settings")
    }

    @Test @MainActor func copyHarnessSessionActionWritesTheProviderID() async {
        let outcome = await AgentChatCopyOperations.harnessSessionID(info: { ["agentSessionId": "claude-456"] }, fallback: nil, isCurrent: { true })
        #expect(Self.copiedText(outcome) == "claude-456")
    }

    @Test @MainActor func copyConversationActionWritesMarkdown() async {
        let outcome = await AgentChatCopyOperations.conversation({ "**User:**\nhello" }, isCurrent: { true })
        #expect(Self.copiedText(outcome) == "**User:**\nhello")
    }

    @Test @MainActor func delayedConversationPromiseDoesNotReachThePasteboardAfterSwitch() async {
        var current = true
        let outcome = await AgentChatCopyOperations.conversation({
            current = false
            return "**User:**\nold chat"
        }, isCurrent: { current })
        #expect(outcome == .stale)
    }

    @Test @MainActor func copySessionDetailsActionWritesExplicitMetadata() async {
        let outcome = await AgentChatCopyOperations.details(
            info: { ["name": "sr2/nx-settings", "cwd": "/repo", "agentSessionId": "claude-456"] }, files: { nil },
            identifier: "acp-123", fallbackHarnessSessionID: nil, fallbackCWD: nil, host: "lawrence", isCurrent: { true }
        )
        #expect(Self.copiedText(outcome) == "Agent name: sr2/nx-settings\nAgent identifier: acp-123\nHarness session ID: claude-456\nCWD: /repo\nHost: lawrence")
    }

    @Test @MainActor func copyCWDAndHostActionsWriteTheirSeparateValues() async {
        let cwd = await AgentChatCopyOperations.workingDirectory(info: { [:] }, fallback: "/repo", isCurrent: { true })
        let host = await AgentChatCopyOperations.host("lawrence", isCurrent: { true })
        #expect(Self.copiedText(cwd) == "/repo")
        #expect(Self.copiedText(host) == "lawrence")
    }

    @Test @MainActor func delayedCopyDoesNothingAfterSessionSwitch() async {
        var current = true
        let outcome = await AgentChatCopyOperations.name(info: {
            current = false
            return ["name": "old-chat"]
        }, isCurrent: { current })
        #expect(outcome == .stale)
    }

    @Test func agentNameCopiesAsPlainText() {
        let text = AgentChatCopyText.details(name: "sr2/nx-settings", identifier: "acp-123",
                                             harnessSessionID: nil, cwd: nil, host: nil, files: [])
        #expect(text == "Agent name: sr2/nx-settings\nAgent identifier: acp-123")
    }

    @Test func harnessSessionIDCopiesWithoutTheAcpmuxPrefix() {
        let text = AgentChatCopyText.details(name: nil, identifier: "acp-123", harnessSessionID: "claude-456",
                                             cwd: nil, host: nil, files: [])
        #expect(text == "Agent identifier: acp-123\nHarness session ID: claude-456")
    }

    @Test func cwdAndHostRemainSeparateMetadataValues() {
        let text = AgentChatCopyText.details(name: nil, identifier: "acp-123", harnessSessionID: nil,
                                             cwd: "/repo", host: "lawrence", files: [])
        #expect(text.contains("CWD: /repo"))
        #expect(text.contains("Host: lawrence"))
    }

    @Test func detailsKeepIdentityAndHostFieldsExplicit() {
        let text = AgentChatCopyText.details(
            name: "claude",
            identifier: "acp-123",
            harnessSessionID: "claude-456",
            cwd: "/tmp/project",
            host: "This Mac",
            files: []
        )

        #expect(text.contains("Agent name: claude"))
        #expect(text.contains("Agent identifier: acp-123"))
        #expect(text.contains("Harness session ID: claude-456"))
        #expect(text.contains("CWD: /tmp/project"))
        #expect(text.contains("Host: This Mac"))
    }

    private static let sessionFiles: [String: Any] = ["schema": "session-files-v1", "files": [
        ["kind": "claude_config", "path": "/Users/me/.claude/.claude.json"],
        ["kind": "claude_settings", "path": "/Users/me/.claude/settings.json"],
        ["kind": "transcript", "path": "/Users/me/.claude/projects/-repo/claude-456.jsonl"],
        ["kind": "acpmux_session", "path": "/state/sessions/acp-123/session.json"],
        ["kind": "acpmux_events", "path": "/state/sessions/acp-123/events"],
        ["kind": "future_kind", "path": "/state/future"],
    ]]

    @Test @MainActor func copySessionFilePathsListsEveryDaemonPathWithItsLabel() async {
        let outcome = await AgentChatCopyOperations.filePaths(files: { Self.sessionFiles }, isCurrent: { true })
        #expect(Self.copiedText(outcome) == """
        Claude config: /Users/me/.claude/.claude.json
        Claude settings: /Users/me/.claude/settings.json
        Transcript: /Users/me/.claude/projects/-repo/claude-456.jsonl
        acpmux session: /state/sessions/acp-123/session.json
        acpmux events: /state/sessions/acp-123/events
        future_kind: /state/future
        """)
    }

    @Test @MainActor func copySessionFilePathsIsMissingForARemoteOrOlderDaemon() async {
        let remote = await AgentChatCopyOperations.filePaths(files: { nil }, isCurrent: { true })
        let empty = await AgentChatCopyOperations.filePaths(files: { ["files": []] }, isCurrent: { true })
        #expect(remote == .missing)
        #expect(empty == .missing)
    }

    @Test @MainActor func copySessionDetailsIncludesTheSessionFilePaths() async {
        let outcome = await AgentChatCopyOperations.details(
            info: { ["name": "sr2/nx-settings"] }, files: { Self.sessionFiles },
            identifier: "acp-123", fallbackHarnessSessionID: nil, fallbackCWD: nil, host: nil, isCurrent: { true }
        )
        let text = Self.copiedText(outcome) ?? ""
        #expect(text.hasPrefix("Agent name: sr2/nx-settings\nAgent identifier: acp-123\nClaude config: /Users/me/.claude/.claude.json"))
        #expect(text.contains("Transcript: /Users/me/.claude/projects/-repo/claude-456.jsonl"))
    }

    @Test @MainActor func copyFileActionReadsTheFirstMatchingKind() async {
        var reads: [String] = []
        let outcome = await AgentChatCopyOperations.fileContents(
            files: { Self.sessionFiles }, kinds: ["claude_config", "codex_config"],
            read: { path in reads.append(path); return "{\"numStartups\": 3}" }, isCurrent: { true }
        )
        #expect(Self.copiedText(outcome) == "{\"numStartups\": 3}")
        #expect(reads == ["/Users/me/.claude/.claude.json"])
    }

    @Test @MainActor func copyFileActionFallsBackToTheNextKind() async {
        let codex: [String: Any] = ["files": [["kind": "codex_config", "path": "/Users/me/.codex/config.toml"]]]
        let outcome = await AgentChatCopyOperations.fileContents(
            files: { codex }, kinds: ["claude_config", "codex_config"], read: { "model = \"\($0)\"" }, isCurrent: { true }
        )
        #expect(Self.copiedText(outcome) == "model = \"/Users/me/.codex/config.toml\"")
    }

    @Test @MainActor func copyFileActionReportsMissingAndUnreadableFiles() async {
        let missing = await AgentChatCopyOperations.fileContents(
            files: { Self.sessionFiles }, kinds: ["codex_config"], read: { _ in "unused" }, isCurrent: { true }
        )
        let unreadable = await AgentChatCopyOperations.fileContents(
            files: { Self.sessionFiles }, kinds: ["transcript"], read: { _ in nil }, isCurrent: { true }
        )
        #expect(missing == .missing)
        #expect(unreadable == .failed)
    }

    @Test @MainActor func delayedFileReadDoesNotReachThePasteboardAfterSwitch() async {
        var current = true
        let outcome = await AgentChatCopyOperations.fileContents(
            files: { Self.sessionFiles }, kinds: ["transcript"],
            read: { _ in current = false; return "{\"type\":\"user\"}" }, isCurrent: { current }
        )
        #expect(outcome == .stale)
    }

    @Test func sessionFileTextReadsAFileAndRefusesADirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("copy-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.json")
        try Data("{\"id\":\"acp-123\"}".utf8).write(to: file)
        #expect(await AgentPaneModel.sessionCopyFileText(path: file.path) == "{\"id\":\"acp-123\"}")
        #expect(await AgentPaneModel.sessionCopyFileText(path: dir.path) == nil)
        #expect(await AgentPaneModel.sessionCopyFileText(path: dir.appendingPathComponent("absent").path) == nil)
    }

    private static func copiedText(_ outcome: AgentChatCopyOutcome) -> String? {
        guard case .copied(let text) = outcome else { return nil }
        return text
    }
}
