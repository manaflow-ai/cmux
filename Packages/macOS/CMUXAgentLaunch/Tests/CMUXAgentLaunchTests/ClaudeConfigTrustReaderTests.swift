import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeConfigTrustReaderTests {
    private func makeHome() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func write(_ json: String, to path: String) throws {
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func work(_ home: String) -> ClaudeAccount {
        ClaudeAccount(name: "work", configDirectory: home + "/.claude-work", isRegistered: true)
    }

    private let defaultAccount = ClaudeAccount(name: "default", configDirectory: nil, isRegistered: true)

    private func makeWorkDir(_ home: String) throws {
        try FileManager.default.createDirectory(atPath: home + "/.claude-work", withIntermediateDirectories: true)
    }

    @Test func trustedExactPath() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try makeWorkDir(home)
        try write(#"{"projects":{"/p/app":{"hasTrustDialogAccepted":true}}}"#, to: home + "/.claude-work/.claude.json")
        #expect(ClaudeConfigTrustReader.isTrusted(workingDirectory: "/p/app", account: work(home), homeDirectory: home))
        #expect(ClaudeConfigTrustReader.isTrusted(workingDirectory: "/p/app/", account: work(home), homeDirectory: home))
    }

    @Test func trustedViaAncestor() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try makeWorkDir(home)
        try write(#"{"projects":{"/p":{"hasTrustDialogAccepted":true}}}"#, to: home + "/.claude-work/.claude.json")
        #expect(ClaudeConfigTrustReader.isTrusted(workingDirectory: "/p/app/sub", account: work(home), homeDirectory: home))
        #expect(!ClaudeConfigTrustReader.isTrusted(workingDirectory: "/other", account: work(home), homeDirectory: home))
    }

    @Test func untrustedWhenFlagFalse() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try makeWorkDir(home)
        try write(#"{"projects":{"/p/app":{"hasTrustDialogAccepted":false},"/p":{}}}"#, to: home + "/.claude-work/.claude.json")
        #expect(!ClaudeConfigTrustReader.isTrusted(workingDirectory: "/p/app", account: work(home), homeDirectory: home))
    }

    @Test func defaultAccountReadsHomeClaudeJSON() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write(#"{"projects":{"/p":{"hasTrustDialogAccepted":true}}}"#, to: home + "/.claude.json")
        #expect(ClaudeConfigTrustReader.isTrusted(workingDirectory: "/p", account: defaultAccount, homeDirectory: home))
        #expect(!ClaudeConfigTrustReader.isTrusted(workingDirectory: "/p", account: work(home), homeDirectory: home))
    }

    @Test func corruptClaudeJSONIsUntrusted() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write("{", to: home + "/.claude.json")
        #expect(!ClaudeConfigTrustReader.isTrusted(workingDirectory: "/p", account: defaultAccount, homeDirectory: home))
        try FileManager.default.removeItem(atPath: home + "/.claude.json")
        #expect(!ClaudeConfigTrustReader.isTrusted(workingDirectory: "/p", account: defaultAccount, homeDirectory: home))
    }

    @Test func configNeedsTheAccountsClaudeJSON() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let missing = ClaudeAccount(name: "gone", configDirectory: home + "/.claude-gone", isRegistered: true)
        #expect(!ClaudeConfigTrustReader.hasConfig(account: missing, homeDirectory: home))

        try makeWorkDir(home)
        #expect(!ClaudeConfigTrustReader.hasConfig(account: work(home), homeDirectory: home))
        try write("{}", to: home + "/.claude-work/.claude.json")
        #expect(ClaudeConfigTrustReader.hasConfig(account: work(home), homeDirectory: home))

        // The default account keeps its .claude.json in the home, not in ~/.claude.
        #expect(!ClaudeConfigTrustReader.hasConfig(account: defaultAccount, homeDirectory: home))
        try write("{}", to: home + "/.claude.json")
        #expect(ClaudeConfigTrustReader.hasConfig(account: defaultAccount, homeDirectory: home))
        // Checking never creates anything.
        #expect(!FileManager.default.fileExists(atPath: home + "/.claude-gone"))
    }
}
