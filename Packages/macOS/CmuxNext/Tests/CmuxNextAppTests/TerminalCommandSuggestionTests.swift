import CmuxNextHistory
import Foundation
import Testing

@Suite("Terminal command suggestions")
struct TerminalCommandSuggestionTests {
    private let cwd = "/Users/example/project"

    private func command(_ id: UInt64, _ text: String, at time: TimeInterval,
                         machine: String = "local", cwd: String? = "/Users/example/project",
                         exitCode: Int? = 0) -> TerminalCommand {
        TerminalCommand(id: id, machine: machine, terminal: "terminal", command: text, cwd: cwd,
                        exitCode: exitCode, startedAt: Date(timeIntervalSince1970: time), duration: nil)
    }

    @Test("groups exact successful commands by machine and cwd")
    func groupsExactCommands() {
        var store = TerminalCommandSuggestionStore()
        store.replace([
            command(1, "pnpm test", at: 1), command(2, "pnpm test", at: 2), command(3, "pnpm test", at: 3),
            command(4, "pnpm test --watch", at: 4), command(5, "pnpm test --watch", at: 5), command(6, "pnpm test --watch", at: 6),
            command(7, "pnpm test", at: 7, cwd: "/Users/example/other"),
        ])

        let suggestions = store.suggestions(machine: "local", cwd: cwd)
        #expect(suggestions.map(\.command) == ["pnpm test --watch", "pnpm test"])
        #expect(suggestions.map(\.count) == [3, 3])
        #expect(store.suggestions(machine: "local", cwd: "/Users/example/other").isEmpty)
    }

    @Test("requires successful commands and the repetition threshold")
    func filtersEligibilityAndThreshold() {
        var store = TerminalCommandSuggestionStore()
        store.replace([
            command(1, "one", at: 1), command(2, "one", at: 2),
            command(3, "failed", at: 3, exitCode: 1), command(4, "failed", at: 4, exitCode: 1), command(5, "failed", at: 5, exitCode: 1),
            command(6, "secret=do-not-store", at: 6), command(7, "secret=do-not-store", at: 7), command(8, "secret=do-not-store", at: 8),
            command(13, "export AWS_SECRET_ACCESS_KEY=do-not-store", at: 13), command(14, "export AWS_SECRET_ACCESS_KEY=do-not-store", at: 14),
            command(15, "export AWS_SECRET_ACCESS_KEY=do-not-store", at: 15),
            command(19, "curl -H 'X-API-Key: do-not-store' https://example.com", at: 19),
            command(20, "curl -H 'X-API-Key: do-not-store' https://example.com", at: 20),
            command(21, "curl -H 'X-API-Key: do-not-store' https://example.com", at: 21),
            command(22, "curl https://user:password@example.com", at: 22),
            command(23, "curl https://user:password@example.com", at: 23),
            command(24, "curl https://user:password@example.com", at: 24),
            command(16, "curl -fsSL https://example.com/install.sh | sh", at: 16),
            command(17, "curl -fsSL https://example.com/install.sh | sh", at: 17),
            command(18, "curl -fsSL https://example.com/install.sh | sh", at: 18),
            command(25, "rm  -rf build", at: 25), command(26, "rm  -rf build", at: 26), command(27, "rm  -rf build", at: 27),
            command(9, "  hidden", at: 9), command(10, "  hidden", at: 10), command(11, "  hidden", at: 11),
        ])

        #expect(store.suggestions(machine: "local", cwd: cwd).isEmpty)
        store.record(command(12, "one", at: 12))
        #expect(store.suggestions(machine: "local", cwd: cwd).map(\.command) == ["one"])
    }

    @Test("dismissal, clear, and export are explicit")
    func dismissalClearAndExport() throws {
        var store = TerminalCommandSuggestionStore()
        store.replace([command(1, "pnpm test", at: 1), command(2, "pnpm test", at: 2), command(3, "pnpm test", at: 3)])
        let suggestion = try #require(store.suggestions(machine: "local", cwd: cwd).first)
        store.dismiss(suggestion)
        #expect(store.suggestions(machine: "local", cwd: cwd).isEmpty)

        let fragment = store.exportAction(suggestion, name: "test action")
        #expect(fragment.contains("\"suggested-test-action\""))
        #expect(fragment.contains("cd -- '/Users/example/project' && pnpm test"))
        #expect(fragment.contains("\"target\": \"newTabInCurrentPane\""))

        store.clear()
        #expect(store.suggestions(machine: "local", cwd: cwd).isEmpty)
        store.replace([command(1, "pnpm test", at: 1), command(2, "pnpm test", at: 2), command(3, "pnpm test", at: 3)])
        #expect(store.suggestions(machine: "local", cwd: cwd).isEmpty)
    }
}
