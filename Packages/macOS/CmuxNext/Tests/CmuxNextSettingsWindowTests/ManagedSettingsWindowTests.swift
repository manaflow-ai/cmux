import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSettingsWindow
import Foundation
import Testing

/// Managed keys in the Settings window: the row shows who manages it,
/// refuses edits and never offers Reset; recommended values are not
/// customizations.
@MainActor
@Suite struct ManagedSettingsWindowTests {
    func model(file text: String, managed: ManagedPreferences, team: TeamPolicyLayer = .none) async throws -> (SettingsWindowModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-managed-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(text.utf8).write(to: url)
        let registry = ActionRegistry(catalog: [])
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        settings.setTeamPolicy(team)
        await settings.reload()
        return (SettingsWindowModel(settings: settings, registry: registry, host: nil), url)
    }

    @Test func deviceManagedRowIsLockedAndShowsTheOrganization() async throws {
        let (model, url) = try await model(file: "{\"ui\": {\"animationSpeed\": \"fast\"}}", managed: ManagedPreferences(forced: ["ui.animationSpeed": "off"]))
        let speed = try #require(SettingsSchema.descriptor(for: ["ui", "animationSpeed"]))
        #expect(model.isManaged(speed))
        #expect(model.value(speed) == "off")
        #expect(!model.isCustomized(speed))
        #expect(model.diagnostic(speed) == nil)
        #expect(model.managedNote(speed) == "Managed by your organization")
        model.set(speed, "normal")
        await model.settled()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"fast\""))
        #expect(model.value(speed) == "off")
    }

    @Test func teamManagedRowNamesTheTeam() async throws {
        let (model, _) = try await model(file: "{}", managed: .empty, team: TeamPolicyLayer(teamName: "Acme", enforced: ["ui.animationSpeed": "normal"]))
        let speed = try #require(SettingsSchema.descriptor(for: ["ui", "animationSpeed"]))
        #expect(model.managedNote(speed) == "Managed by Acme")
    }

    @Test func recommendedValueIsTheDefaultAndStaysEditable() async throws {
        let (model, url) = try await model(file: "{}", managed: ManagedPreferences(recommended: ["ui.animationSpeed": "off"]))
        let speed = try #require(SettingsSchema.descriptor(for: ["ui", "animationSpeed"]))
        #expect(!model.isManaged(speed))
        #expect(model.value(speed) == "off")
        #expect(!model.isCustomized(speed))
        model.set(speed, "normal")
        await model.settled()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"normal\""))
        #expect(model.value(speed) == "normal")
    }
}
