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
            info: { ["name": "sr2/nx-settings", "cwd": "/repo", "agentSessionId": "claude-456"] },
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

    private static func copiedText(_ outcome: AgentChatCopyOutcome) -> String? {
        guard case .copied(let text) = outcome else { return nil }
        return text
    }
}
