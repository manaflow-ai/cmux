import CmuxNextActions
@testable import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The production Settings provider and loaded harness model, with terminal IO intercepted.
@MainActor struct SettingsAgentUpdateContextTests {
    @MainActor final class Recorder {
        var lines: [String] = []
    }

    private func make() async throws -> (page: SettingsPageProvider, harnesses: SettingsHarnesses, recorder: Recorder, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-agent-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let recorder = Recorder()
        let environment = AcpmuxEnvironment(executable: directory.appending(path: "acpmux"), home: directory,
            socketPath: directory.appending(path: "a.sock").path, daemonArguments: [], childEnvironment: [:])
        let health = Data(#"{"harnesses":[{"id":"codex","outdated":true,"update":{"argv":["npm","install","-g","@openai/codex@latest"],"elevated":false}}]}"#.utf8)
        let harnesses = SettingsHarnesses(environment: { environment },
            fetch: { _ in [.init(id: "codex", kind: "acp", source: "path")] },
            fetchHealth: { _, _ in health }, openTerminal: { recorder.lines.append($0) })
        await harnesses.refresh()
        let page = SettingsPageProvider(settings: settings)
        page.harnessesRun = { params, context in try await harnesses.run(params, context: context) }
        return (page, harnesses, recorder, directory)
    }

    private func params(_ action: String) -> JSONValue {
        ["action": .string(action), "id": "codex", "origin": "user", "confirmed": true, "userGesture": true]
    }

    private func context(_ mode: String) -> PageCallContext {
        PageCallContext(page: "cmux.settings", origin: mode == "confirmed" || mode == "claim-user" ? "user" : "page",
            confirmed: mode == "confirmed", opid: "original-operation", userGesture: mode == "gesture",
            gestureEvent: mode == "gesture" ? 123 : nil)
    }

    @Test(arguments: ["update", "updateAll"], ["script", "claim-user", "absent"])
    func untrustedPageCallsCannotReachTheTerminalHandoff(action: String, mode: String) async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        do {
            if mode == "absent" {
                _ = try await h.harnesses.run(params(action), context: nil)
            } else {
                _ = try await h.page.call("cmux.settings.harnesses.run", params: params(action), context: context(mode))
            }
            Issue.record("an untrusted page call reached the update handoff")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(h.recorder.lines.isEmpty)
    }

    @Test(arguments: ["update", "updateAll"], ["gesture", "confirmed"])
    func aRealGestureOrNativeConfirmationRetainsTheExistingHandoff(action: String, mode: String) async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        _ = try await h.page.call("cmux.settings.harnesses.run", params: params(action), context: context(mode))
        #expect(h.recorder.lines == ["'npm' 'install' '-g' '@openai/codex@latest'"])
    }

    @Test(arguments: ["script", "gesture", "confirmed"])
    func theProviderRetainsTheOriginalContextAndOperationIdentity(mode: String) async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        var received: PageCallContext?
        h.page.harnessesRun = { _, context in received = context; return .null }
        let original = context(mode)
        _ = try await h.page.call("cmux.settings.harnesses.run", params: params("update"), context: original)
        #expect(received == original)
    }

    /// Turning Update Automatically on lets acpmux run the update after its next check, so it
    /// needs the person too; turning it off does not.
    @Test(arguments: ["script", "claim-user"])
    func anUntrustedPageCannotTurnOnAutomaticUpdates(mode: String) async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let on: JSONValue = ["action": "autoUpdate", "id": "codex", "on": true]
        await #expect(throws: PageError.self) {
            do { _ = try await h.page.call("cmux.settings.harnesses.run", params: on, context: context(mode)) }
            catch let error as PageError { #expect(error.code == PageNativeOp.userOnlyCode); throw error }
        }
        let off: JSONValue = ["action": "autoUpdate", "id": "codex", "on": false]
        do { _ = try await h.page.call("cmux.settings.harnesses.run", params: off, context: context(mode)) }
        catch let error as PageError { #expect(error.code != PageNativeOp.userOnlyCode) }
        catch {}
    }

    @Test func aRefreshRemainsAvailableWithoutAnExecutionGesture() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        _ = try await h.page.call("cmux.settings.harnesses.run", params: ["action": "refresh"], context: context("script"))
        #expect(h.harnesses.rows.map(\.id) == ["codex"])
        #expect(h.recorder.lines.isEmpty)
    }
}
