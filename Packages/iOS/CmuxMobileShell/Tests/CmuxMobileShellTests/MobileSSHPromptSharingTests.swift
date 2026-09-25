@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

/// Two connections to one new computer can ask the same trust question at
/// once: saving a computer from the editor auto-connects it while "Install
/// with Password" logs in with the password. One answer must settle both;
/// the second asker must not cancel the first (which failed the password
/// install with "server identity not trusted" before the user answered).
@MainActor
@Suite struct MobileSSHPromptSharingTests {
    private static let serverKey = SSHHostKey(openSSHString: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
    private static let otherKey = SSHHostKey(openSSHString: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAMWEbZQTv80iklO2Rvvjv24a6iWnuhQuiQpxGInW/n4")

    private func makeRuntime() async throws -> (MobileSSHComputers, SSHHostRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-prompt-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let host = SSHHostRecord(name: "New", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        return (computers, host)
    }

    @Test func concurrentAsksOfTheSameQuestionShareOneAnswer() async throws {
        let (computers, host) = try await makeRuntime()
        let prompt = MobileSSHPrompt.trustNewHostKey(host: host, key: Self.serverKey)
        let installAsk = Task { await computers.ask(prompt) }
        while computers.prompts.isEmpty { await Task.yield() }
        var autoConnectAsked = false
        let autoConnectAsk = Task {
            autoConnectAsked = true
            return await computers.ask(prompt)
        }
        while !autoConnectAsked { await Task.yield() }
        await Task.yield()
        #expect(computers.prompts.count == 1, "one question on screen, not two")

        computers.answer(prompt, with: .trust)
        #expect(await installAsk.value == .trust)
        #expect(await autoConnectAsk.value == .trust)
        #expect(computers.prompts.isEmpty)
    }

    @Test func aDifferentKeyForTheSameHostReplacesTheStaleQuestion() async throws {
        let (computers, host) = try await makeRuntime()
        let stale = MobileSSHPrompt.trustNewHostKey(host: host, key: Self.serverKey)
        let fresh = MobileSSHPrompt.trustNewHostKey(host: host, key: Self.otherKey)
        let staleAsk = Task { await computers.ask(stale) }
        while computers.prompts.isEmpty { await Task.yield() }
        let freshAsk = Task { await computers.ask(fresh) }
        // Trusting one key must never answer a question about another.
        #expect(await staleAsk.value == .cancel)
        computers.answer(fresh, with: .trust)
        #expect(await freshAsk.value == .trust)
    }
}
