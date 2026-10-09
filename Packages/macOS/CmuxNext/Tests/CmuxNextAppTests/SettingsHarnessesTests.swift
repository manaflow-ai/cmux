import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Settings > Agents > Harnesses (cx-mg91): the page's state comes from acpmux's harnesses, and
/// Sign In, Check and Browse ACP Registry open a terminal tab with this app's acpmux command.
@MainActor @Suite struct SettingsHarnessesTests {
    private let environment = AcpmuxEnvironment(
        executable: URL(fileURLWithPath: "/b/acpmux"), home: URL(fileURLWithPath: "/h", isDirectory: true),
        socketPath: "/h/acpmux.sock", daemonArguments: [], childEnvironment: ["ACPMUX_HOME": "/h"]
    )
    private let listed = [
        AcpmuxHarnessRow(id: "codex", kind: "acp", source: "path"),
        AcpmuxHarnessRow(id: "aider", name: "Aider", kind: "terminal", source: "user-file"),
    ]

    private func model(_ lines: TypedLines, environment: AcpmuxEnvironment?, fails: Bool = false) -> SettingsHarnesses {
        let rows = listed
        return SettingsHarnesses(environment: { environment }, fetch: { _ in
            if fails { throw URLError(.cannotConnectToHost) }
            return rows
        }, openTerminal: { lines.value.append($0) })
    }

    @Test func refreshFillsTheStateTheHarnessesCardDraws() async throws {
        let lines = TypedLines()
        let harnesses = model(lines, environment: environment)
        await harnesses.refresh()
        let state = harnesses.state
        #expect(state["problem"] == .null)
        #expect(state["loading"] == .bool(false))
        let rows = try #require(state["harnesses"]?.arrayValue)
        #expect(rows.map { $0["id"]?.stringValue } == ["codex", "aider"])
        #expect(rows[0]["name"] == .null)
        #expect(rows[1]["kind"] == .string("terminal"))
        #expect(lines.value.isEmpty)
    }

    @Test func signInAndCheckOpenATerminalWithHarnessLogin() async throws {
        let lines = TypedLines()
        let harnesses = model(lines, environment: environment)
        await harnesses.refresh()
        _ = try await harnesses.run(["action": "signIn", "id": "codex"])
        _ = try await harnesses.run(["action": "check", "id": "codex"])
        _ = try await harnesses.run(["action": "registry"])
        #expect(lines.value == [
            "ACPMUX_HOME='/h' '/b/acpmux' 'harness' 'login' 'codex'",
            "ACPMUX_HOME='/h' '/b/acpmux' 'harness' 'login' 'codex' '--status'",
            "ACPMUX_HOME='/h' '/b/acpmux' 'harness' 'registry'",
        ])
    }

    @Test func onlyAListedAcpHarnessCanBeSignedIn() async throws {
        let lines = TypedLines()
        let harnesses = model(lines, environment: environment)
        await harnesses.refresh()
        for params: JSONValue in [["action": "signIn", "id": "evil; rm -rf ~"], ["action": "signIn", "id": "aider"],
                                  ["action": "signIn"], ["action": "launch", "id": "codex"]] {
            await #expect(throws: PageError.self) { _ = try await harnesses.run(params) }
        }
        #expect(lines.value.isEmpty)
    }

    @Test func noAcpmuxOrNoAnswerIsAProblemNotAnEmptyList() async {
        let lines = TypedLines()
        let missing = model(lines, environment: nil)
        await missing.refresh()
        #expect(missing.state["problem"] == .string("unavailable"))
        let silent = model(lines, environment: environment, fails: true)
        await silent.refresh()
        #expect(silent.state["problem"] == .string("unreachable"))
        #expect(silent.state["harnesses"]?.arrayValue?.isEmpty == true)
    }

    @Test func theSettingsPageRoutesTheHarnessesOps() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "settings-harnesses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let provider = SettingsPageProvider(settings: settings)
        let context = PageCallContext(page: "cmux.settings")
        await #expect(throws: PageError.self) { _ = try await provider.call("cmux.settings.harnesses.state", params: [:], context: context) }
        let lines = TypedLines()
        let harnesses = model(lines, environment: environment)
        provider.harnessesState = { harnesses.state }
        provider.harnessesRun = { try await harnesses.run($0) }
        _ = try await provider.call("cmux.settings.harnesses.run", params: ["action": "refresh"], context: context)
        let state = try await provider.call("cmux.settings.harnesses.state", params: [:], context: context)
        #expect(state["harnesses"]?.arrayValue?.count == 2)
    }
}

/// The lines `openTerminal` typed.
@MainActor private final class TypedLines {
    var value: [String] = []
}
