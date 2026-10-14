@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Labs on the New Tab page (hq#1980): in team builds the page lists each Labs flag with a toggle,
/// so the team tries prototypes where they start work. A toggle (`newTab.setLab`) is saved as
/// `labs.<flag>` in cmux.json, as Settings > Labs saves it; "All Labs…" opens that list.
@MainActor
struct NewTabLabsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func settings() async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-newtab-labs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appending(path: "cmux.json"))
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(),
                                          fileURL: directory.appending(path: "cmux.json"),
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, directory)
    }

    private static func toggle(_ model: AgentPaneModel, _ flag: String, _ on: Bool) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": "newTab.setLab", "params": ["flag": flag, "on": on]]))
    }

    @Test func aLabTurnedOnOnThePageIsSavedInCmuxJSON() async throws {
        let (settings, directory) = try await Self.settings()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        // Each save is kept and awaited, as NewTabStyleSwitchTests does (#20423): the reload reads
        // the file on a detached task, which yields on this actor do not wait for.
        var saves: [Task<Void, Never>] = []
        model.onNewTabSetting = { change in saves.append(Task { await NewTabPage.save(change, settings: settings) }) }

        let reply = await Self.toggle(model, "previewFeatures", true)
        #expect(reply["ok"] as? Bool == true)
        for save in saves { await save.value }
        #expect(settings.snapshot.lab(.previewFeatures, teamBuild: false))

        _ = await Self.toggle(model, "previewFeatures", false)
        for save in saves { await save.value }
        #expect(!settings.snapshot.lab(.previewFeatures, teamBuild: true))

        // A name that is not a Labs flag writes nothing.
        let before = try String(contentsOf: directory.appending(path: "cmux.json"), encoding: .utf8)
        _ = await Self.toggle(model, "notAFlag", true)
        #expect(saves.count == 3)
        for save in saves { await save.value }
        #expect(try String(contentsOf: directory.appending(path: "cmux.json"), encoding: .utf8) == before)
    }

    @Test func allLabsOpensTheFullListInSettings() async {
        let model = AgentPaneModel(host: NoHost(), allowsTabConversion: true)
        var ran: [String] = []
        model.onRunAction = { id in ran.append(id); return true }
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "action.run", "params": ["id": "help.featureFlags"]]))
        #expect(reply["ok"] as? Bool == true)
        #expect(ran == ["help.featureFlags"])
    }
}
