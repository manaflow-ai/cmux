import Foundation
import Testing
@testable import CmuxSessionIndex

@Suite("SessionAgent coding")
struct SessionAgentCodingTests {
    @Test("Built-in agents encode as bare strings and round-trip")
    func builtInRoundTrip() throws {
        for agent in SessionAgent.builtInCases {
            let data = try JSONEncoder().encode(agent)
            let decoded = try JSONDecoder().decode(SessionAgent.self, from: data)
            #expect(decoded == agent)
            let raw = String(decoding: data, as: UTF8.self)
            #expect(raw == "\"\(agent.rawValue)\"")
        }
    }

    @Test("hermes-agent raw value is the hyphenated wire string")
    func hermesRawValue() {
        #expect(SessionAgent.hermesAgent.rawValue == "hermes-agent")
        #expect(SessionAgent(rawValue: "hermes-agent") == .hermesAgent)
    }

    @Test("Invalid raw value yields nil")
    func invalidRawValue() {
        #expect(SessionAgent(rawValue: "  ") == nil)
    }
}

@Suite("SessionEntry helpers")
struct SessionEntryHelperTests {
    private func entry(specifics: AgentSpecifics, cwd: String? = nil) -> SessionEntry {
        SessionEntry(
            id: "id",
            agent: .codex,
            sessionId: "sess-123",
            title: "title",
            cwd: cwd,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: specifics
        )
    }

    @Test("codex bypass round-trips to the single combined flag")
    func codexBypassFlag() {
        let args = SessionEntry.codexApprovalSandboxArguments(
            approvalPolicy: "never",
            sandboxMode: "disabled"
        )
        #expect(args == ["--dangerously-bypass-approvals-and-sandbox"])
    }

    @Test("codex drops sandbox types with no CLI equivalent")
    func codexDropsUnknownSandbox() {
        let args = SessionEntry.codexApprovalSandboxArguments(
            approvalPolicy: "on-request",
            sandboxMode: "managed"
        )
        #expect(args == ["-a 'on-request'"])
    }

    @Test("resumeWorkingDirectory is nil for empty cwd")
    func resumeWorkingDirectoryEmpty() {
        #expect(entry(specifics: .rovodev, cwd: "").resumeWorkingDirectory == nil)
        #expect(entry(specifics: .rovodev, cwd: "/tmp/x").resumeWorkingDirectory == "/tmp/x")
    }

    @Test("claude slash-command title is parsed from tags")
    func claudeSlashCommandTitle() {
        let raw = "<command-name>/foo</command-name><command-message>bar</command-message>"
        #expect(SessionEntry.claudeDisplayTitle(from: raw) == "/foo bar")
    }

    @Test("synthetic envelopes are detected")
    func syntheticEnvelopes() {
        #expect(SessionEntry.isClaudeLocalCommandEnvelope("<local-command-stdout>x"))
        #expect(SessionEntry.isClaudeSyntheticEnvelope("<system-reminder>x"))
        #expect(SessionEntry.claudeDisplayTitle(from: "<system-reminder>x") == nil)
    }
}
