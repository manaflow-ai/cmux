@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// The New Tab page chooses its style again (Leo 2026-10-13): a style picked on the page
/// (`newTab.setTemplate`) is saved as `tabs.newTabTemplate`, so every later New Tab shows it.
/// Terminal is not a style the page sets: New Tab never opens a terminal by itself.
@MainActor
struct NewTabStyleSwitchTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func settings() async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-newtab-style-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"tabs":{"newTabTemplate":"terminal"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, directory)
    }

    private static func pick(_ model: AgentPaneModel, _ template: String) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "newTab.setTemplate", "params": ["template": template]]))
    }

    @Test func aStylePickedOnThePageIsSavedForEveryNewTab() async throws {
        let (settings, directory) = try await Self.settings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        // The app saves in a Task (NewTabPage.handler); the test keeps each one and awaits it, so
        // the snapshot is read after the write and its reload, not after a guessed number of yields
        // (the reload reads the file on a detached task, which yields on this actor do not wait for).
        var saves: [Task<Void, Never>] = []
        model.onEditNewTab = { edit in if case .template(let template) = edit { saves.append(Task { await settings.saveNewTabTemplate(template) }) } }

        let reply = await Self.pick(model, "threads")
        #expect(reply["ok"] as? Bool == true)
        #expect(saves.count == 1)
        for save in saves { await save.value }
        #expect(settings.snapshot.newTabTemplate == .threads)
        let saved = try String(contentsOf: directory.appending(path: "cmux.json"), encoding: .utf8)
        #expect(saved.contains("\"threads\""))

        // Terminal and unknown values are not page styles: the setting stays. A stale Composer
        // pick is normalized to Minimal before it reaches the saved config.
        _ = await Self.pick(model, "terminal")
        _ = await Self.pick(model, "sparkles")
        _ = await Self.pick(model, "composer")
        #expect(saves.count == 4)
        for save in saves { await save.value }
        #expect(settings.snapshot.newTabTemplate == .minimal)
        let migrated = try String(contentsOf: directory.appending(path: "cmux.json"), encoding: .utf8)
        #expect(migrated.contains("\"minimal\""))
        #expect(!migrated.contains("\"composer\""))
    }
}
