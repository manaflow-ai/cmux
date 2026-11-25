import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// App menu > Customizations (ask-931361017e): every Experiments and Labs switch, read from the schema,
/// flipped through the guarded write.
@MainActor @Suite(.serialized) struct QuickToggleGroupsTests {
    static func settings(_ json: String = "{}", managed: ManagedPreferences = ManagedPreferences()) throws -> (SettingsController, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-quick-toggles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appending(path: "cmux-next.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(managed), managedWatchFiles: [])
        return (settings, home)
    }

    static func ids(_ group: QuickToggleGroup) -> [String] { group.rows.map(\.id) }

    @Test func experimentsThenLabsWithEverySwitchInSchemaOrder() {
        let groups = SettingsSchema.quickToggleGroups(developerTools: true)
        #expect(groups.count == 2)
        let experiments = Self.ids(groups[0])
        let labs = Self.ids(groups[1])
        #expect(experiments == SettingsSchema.experimentToggles.filter { $0.isPaletteListed(developerTools: true) }.map(\.id))
        #expect(experiments.contains("experiments.agentBadges"))
        #expect(labs.contains("labs.previewFeatures"))
        #expect(labs.contains("customize.fromTheApp"))
        let labsSwitches = SettingsSchema.all.filter {
            $0.path.first == "labs" && $0.kind == .toggle && $0.isPaletteListed(developerTools: true)
        }.map(\.id)
        #expect(labsSwitches.allSatisfy(labs.contains))
        // Schema order, and nothing but on/off switches (the Voice Room address is text).
        let order = SettingsSchema.all.map(\.id)
        #expect(labs == labs.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
        #expect(!labs.contains("labs.voiceRoomURL"))
        #expect((groups[0].rows + groups[1].rows).allSatisfy { $0.kind == .toggle })
        #expect(Set(experiments).isDisjoint(with: labs))
    }

    @Test func onlyRowsThePaletteListsInThisBuild() {
        for developerTools in [true, false] {
            for row in SettingsSchema.quickToggleGroups(developerTools: developerTools).flatMap(\.rows) {
                #expect(row.isPaletteListed(developerTools: developerTools), "\(row.id)")
            }
        }
    }

    @Test func aClickFlipsTheSwitchThroughTheFile() async throws {
        let (settings, home) = try Self.settings()
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        let badges = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.agentBadgesPath))
        #expect(!settings.isOn(badges))
        #expect(!settings.isLocked(badges))

        try await settings.flip(badges)
        await settings.reload()
        #expect(settings.isOn(badges))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: "cmux-next.json"))) as? [String: Any]
        #expect((saved?["experiments"] as? [String: Any])?["agentBadges"] as? Bool == true)

        try await settings.flip(badges)
        await settings.reload()
        #expect(!settings.isOn(badges))
    }

    @Test func aManagedSwitchIsLockedAndRefusesTheClick() async throws {
        let (settings, home) = try Self.settings(managed: ManagedPreferences(forced: ["labs.previewFeatures": .bool(true)]))
        defer { try? FileManager.default.removeItem(at: home) }
        await settings.reload()
        let preview = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.previewFeaturesPath))
        #expect(settings.isLocked(preview))
        #expect(settings.isOn(preview))
        await #expect(throws: SettingManaged.self) { try await settings.flip(preview) }
    }
}
