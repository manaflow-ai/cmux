import CmuxSettings
import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Mobile task custom Claude executable")
struct MobileTaskModelCustomClaudePathTests {
    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func configuredExecutableReceivesControlRequestAsLiteralPath(shellPath: String) async throws {
        let fixture = try MobileTaskClaudeExecutableFixture(shellPath: shellPath)
        defer { try? fixture.remove() }
        let executable = try fixture.executable(
            named: "Claude's $(printf INJECTED); tool",
            modelID: "custom-model"
        )
        let discovery = MobileTaskModelDiscovery.live(
            homeDirectory: fixture.directory,
            shellPath: fixture.shell.path,
            customClaudePath: { executable.path }
        )

        let result = await discovery.models(for: .claude)

        #expect(result.error == nil)
        #expect(result.source == .discovered)
        try #require(result.models.map(\.id) == ["custom-model"])
        let request = try #require(
            JSONSerialization.jsonObject(
                with: Data(fixture.recorded("request", for: executable).utf8)
            ) as? [String: Any]
        )
        #expect(request["type"] as? String == "control_request")
        #expect(request["request_id"] as? String == "cmux-list-options")
        #expect((request["request"] as? [String: String]) == ["subtype": "list_models"])
        #expect(try fixture.recorded("arguments", for: executable).split(separator: "\n") == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--include-partial-messages", "--verbose",
        ])
        #expect(try fixture.recorded("entrypoint", for: executable) == "cmux-task-models")
    }

    @Test func failedCustomExecutableIsAvailableEvenWhenClaudeIsNotOnPATH() async throws {
        let fixture = try MobileTaskClaudeExecutableFixture(shellPath: "/bin/bash")
        defer { try? fixture.remove() }
        let executable = try fixture.executable(
            named: "Claude's pinned build",
            modelID: "unused",
            exitCode: 42
        )
        let discovery = MobileTaskModelDiscovery.live(
            homeDirectory: fixture.directory,
            shellPath: fixture.shell.path,
            customClaudePath: { executable.path }
        )

        let result = await discovery.models(for: .claude)

        #expect(result.models.isEmpty)
        #expect(result.error == .queryFailed)
    }

    @Test func missingCustomExecutableDoesNotUseAnotherClaudeOnPATH() async throws {
        let fixture = try MobileTaskClaudeExecutableFixture(shellPath: "/bin/bash")
        defer { try? fixture.remove() }
        _ = try fixture.executable(named: "claude", modelID: "wrong-installation")
        let missing = fixture.directory.appendingPathComponent("missing Claude").path
        let discovery = MobileTaskModelDiscovery.live(
            homeDirectory: fixture.directory,
            shellPath: fixture.shell.path,
            customClaudePath: { missing }
        )

        let result = await discovery.models(for: .claude)

        #expect(result.models.isEmpty)
        #expect(result.error == .providerUnavailable)
        #expect(!FileManager.default.fileExists(atPath: fixture.defaultExecutable.path + ".request"))
    }

    @Test func settingChangesRefreshTheCatalogAndClearingItRestoresPATH() async throws {
        let fixture = try MobileTaskClaudeExecutableFixture(shellPath: "/bin/bash")
        defer { try? fixture.remove() }
        let first = try fixture.executable(named: "Claude one", modelID: "first-model")
        let second = try fixture.executable(named: "Claude two", modelID: "second-model")
        _ = try fixture.executable(named: "claude", modelID: "path-model")
        let suite = "cmux-task-models-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AgentIntegrationSettingsStore(defaults: defaults)
        let key = IntegrationsCatalogSection().claudeCodeCustomClaudePath
        key.set(first.path, in: defaults)
        let discovery = MobileTaskModelDiscovery.live(
            homeDirectory: fixture.directory,
            shellPath: fixture.shell.path,
            customClaudePath: { settings.customClaudePath }
        )

        let initial = await discovery.models(for: .claude)
        try #require(initial.models.map(\.id) == ["first-model"])
        try fixture.clearRecordings(for: first)
        #expect(await discovery.models(for: .claude) == initial)
        #expect(!FileManager.default.fileExists(atPath: first.path + ".request"))

        key.set(second.path, in: defaults)
        #expect(await discovery.models(for: .claude).models.map(\.id) == ["second-model"])

        key.set(" \n", in: defaults)
        #expect(await discovery.models(for: .claude).models.map(\.id) == ["path-model"])
    }

    @Test func unsetCustomPathKeepsLoginShellLookup() async throws {
        let fixture = try MobileTaskClaudeExecutableFixture(shellPath: "/bin/bash")
        defer { try? fixture.remove() }
        _ = try fixture.executable(named: "claude", modelID: "path-model")
        let discovery = MobileTaskModelDiscovery.live(
            homeDirectory: fixture.directory,
            shellPath: fixture.shell.path
        )

        #expect(await discovery.models(for: .claude).models.map(\.id) == ["path-model"])
    }
}
