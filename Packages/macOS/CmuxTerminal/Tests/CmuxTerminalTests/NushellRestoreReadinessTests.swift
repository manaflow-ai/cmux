import Foundation
import Testing
@testable import CmuxTerminal

@Suite
struct NushellRestoreReadinessTests {
    @Test(arguments: [false, true])
    func actualStartupPayloadDeterminesReadiness(integrationExists: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nu = root.appendingPathComponent("nushell")
        try FileManager.default.createDirectory(at: nu, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "print 'bootstrap'".write(to: nu.appendingPathComponent("cmux-nushell-bootstrap.nu"), atomically: true, encoding: .utf8)
        if integrationExists {
            try "# prompt hooks".write(to: nu.appendingPathComponent("cmux-nushell-integration.nu"), atomically: true, encoding: .utf8)
        }
        var environment: [String: String] = [:]
        var protected: Set<String> = []
        let plan = TerminalSurface.applyManagedShellStartupPlan(
            shell: "/usr/local/bin/nu", integrationDir: root.path,
            userGhosttyShellIntegrationMode: "detect", to: &environment, protectedKeys: &protected
        )
        let command = try #require(plan.command)
        #expect(command.contains("bootstrap"))
        #expect(command.contains("source ") == integrationExists)
        #expect(TerminalShellPromptReadinessPolicy().reportsPromptReadiness(
            integrationDirectory: root.path, resolvedCommand: command, hasUserGhosttyCommand: false,
            resolvedShell: "/usr/local/bin/nu", managedShellCommand: command, environment: environment,
            managedShellReportsPromptReadiness: plan.reportsPromptReadiness
        ) == integrationExists)
    }
}
