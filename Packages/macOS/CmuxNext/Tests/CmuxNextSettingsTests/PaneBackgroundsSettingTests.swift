import CmuxNextActions
import CmuxNextAppearance
@testable import CmuxNextSettings
import Foundation
import Testing

/// `appearance.paneBackgrounds` (plans/cmux-next/pane-backgrounds-DESIGN.md): one background for
/// the window by default, one per pane when asked; agents may set it (looks only) and the window
/// takes it live.
@MainActor @Suite(.serialized) struct PaneBackgroundsSettingTests {
    @Test func itIsSharedByDefault() {
        let (mode, diagnostic) = PaneBackgroundsSetting.parse(.object([:]))
        #expect(mode == .shared)
        #expect(diagnostic == nil)
    }

    @Test func perPaneParses() {
        let (mode, diagnostic) = PaneBackgroundsSetting.parse(.object(["appearance": .object(["paneBackgrounds": .string("perPane")])]))
        #expect(mode == .perPane)
        #expect(diagnostic == nil)
    }

    @Test func aBadValueIsSharedWithADiagnostic() {
        let (mode, diagnostic) = PaneBackgroundsSetting.parse(.object(["appearance": .object(["paneBackgrounds": .string("each")])]))
        #expect(mode == .shared)
        #expect(diagnostic?.path == "appearance.paneBackgrounds")
    }

    @Test func anAgentSetsItAndTheDesignFollows() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "cn-pane-backgrounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let design = DesignSettings()
        let settings = SettingsController(registry: .standard(), design: design, fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        #expect(design.paneBackgrounds == .shared)
        try await settings.setSetting(at: PaneBackgroundsSetting.configPath, to: .string("perPane"), by: .caller("mcp"))
        #expect(settings.applied.paneBackgrounds == .perPane)
        #expect(design.paneBackgrounds == .perPane)
    }
}
