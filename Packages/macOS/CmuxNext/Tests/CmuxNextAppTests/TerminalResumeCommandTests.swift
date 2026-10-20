import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Set, Edit and Clear Resume Command (`terminal-resume-command-v1`): the command a terminal's
/// new shell runs when the terminal restarts (a respawn after its host was lost, or Restart).
/// The daemon stores it with the terminal and shows it on the tab; the palette, the CLI and MCP
/// all run the one action, against a real cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TerminalResumeCommandTests {
    static let ids: [ActionID] = ["resumeCommandSet", "resumeCommandEdit", "resumeCommandClear"]

    /// `set-terminal-resume-command` always sends `command`: a string sets it, null clears it.
    @Test func theRequestAlwaysSendsTheCommandAndNullClearsIt() throws {
        func sent(_ command: String?) throws -> [String: Any] {
            let data = try WireCoding.encoder().encode(SetTerminalResumeCommandRequest(surface: 7, command: command))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try sent("claude --resume abc")["command"] as? String == "claude --resume abc")
        #expect(try sent("x")["surface"] as? Int == 7)
        #expect(try sent(nil)["command"] is NSNull, "a clear sends null, never leaves the key out")
        #expect(SetTerminalResumeCommandRequest.command == "set-terminal-resume-command")
        #expect(SetTerminalResumeCommandRequest.requiredCapability == "terminal-resume-command-v1")
        #expect(DaemonCapabilities.shared.optional.contains("terminal-resume-command-v1"))
    }

    @Test func setEditAndClearChangeTheTabsResumeCommand() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-resume-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let launcher = DaemonLauncher(configuration: .init(binary: binary, session: "cn-resume-\(UUID().uuidString.prefix(6).lowercased())",
                                                           stateDirectory: root.appendingPathComponent("state")), environment: environment)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let result: Result<Void, any Error>
        do {
            try await Self.setEditAndClear(services)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    private static func setEditAndClear(_ services: AppServices) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        func until(_ done: () -> Bool) async {
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        func terminal() -> TabModel? {
            services.daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.kind == .pty && !$0.dead }
        }
        await until { terminal() != nil && services.daemon.supports(DaemonCapabilities.shared.terminalResumeCommand) }
        let tab = try #require(terminal(), "the daemon showed no terminal tab")
        for id in ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id.rawValue) is greyed out")
        }
        func run(_ id: ActionID, _ command: String? = nil) -> String? {
            let arguments: [String: ActionValue] = command.map { ["command": .string($0)] } ?? [:]
            return services.registry.capturingRefusal {
                _ = services.registry.perform(id, invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: tab.id), arguments: arguments))
            }
        }

        #expect(run("resumeCommandClear") != nil, "nothing to clear: refused with a reason")
        #expect(run("resumeCommandSet", "claude --resume abc") == nil)
        await until { tab.resumeCommand == "claude --resume abc" }
        #expect(tab.resumeCommand == "claude --resume abc", "the daemon did not store the command")

        #expect(run("resumeCommandEdit", "codex resume xyz") == nil)
        await until { tab.resumeCommand == "codex resume xyz" }
        #expect(tab.resumeCommand == "codex resume xyz")

        #expect(run("resumeCommandClear") == nil)
        await until { tab.resumeCommand == nil }
        #expect(tab.resumeCommand == nil, "the command was not cleared")
    }
}
