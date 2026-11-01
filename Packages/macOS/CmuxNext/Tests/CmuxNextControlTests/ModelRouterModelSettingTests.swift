import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import CmuxNextCompat
import Testing

/// The cmux model router's model (`agents.modelRouter.model`, user 2026-10-28): one setting that
/// Settings, the command palette, `cmux settings set` and MCP (`settings.set`) all write through the
/// settings owner. It offers only the router's DeepSeek models, and DeepSeek V4.1 Flash 1017 (images)
/// is the default; any other model id is refused before the file changes.
@MainActor @Suite(.serialized) struct ModelRouterModelSettingTests {
    static let path = "agents.modelRouter.model"

    func make() throws -> (ControlRouter, SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-model-router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), settings: settings.file, settingsWriter: settings,
                                   configuration: .init(requestDeadline: .seconds(10)))
        return (router, settings, directory)
    }

    func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: method, params: params))
    }

    @Test func settingsSetWritesARouterModelAndRefusesAnyOther() async throws {
        let (router, settings, directory) = try make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let set = await call(router, "settings.set", ["path": .string(Self.path), "value": .string("deepseek/deepseek-v4.1-flash")])
        #expect((try? set.get()) != nil, "\(set)")
        #expect(try await settings.file.value(at: ["agents", "modelRouter", "model"]) == .string("deepseek/deepseek-v4.1-flash"))
        guard case .failure(let refused) = await call(router, "settings.set", ["path": .string(Self.path), "value": .string("anthropic/claude-opus-5-5")]) else {
            Issue.record("a model the router does not serve was accepted")
            return
        }
        #expect(refused.code == "invalid_params")
    }

    @Test func theDefaultIsDeepSeekFlash1017AndThePaletteOffersEveryChoice() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["agents", "modelRouter", "model"]))
        #expect(descriptor.defaultValue == .string("deepseek/deepseek-v4.1-flash-1017"))
        #expect(descriptor.isPaletteExposed)
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("the model router setting is not a choice")
            return
        }
        #expect(choices.map(\.value).first == "deepseek/deepseek-v4.1-flash-1017")
        #expect(choices.allSatisfy { $0.value.hasPrefix("deepseek/") })
    }
}
