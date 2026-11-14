import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Proves sidebar customization follows the real config file watcher, including
/// an editor-style atomic replace, rather than a test-only reload call.
@MainActor @Suite(.serialized) struct SidebarCustomizationWatcherTests {
    @Test func atomicConfigSaveReloadsSidebarProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-sidebar-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cmux-next.json")
        try Data(#"{}"#.utf8).write(to: file)
        let design = DesignSettings()
        let settings = SettingsController(registry: .standard(), design: design, fileURL: file,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        settings.start()
        defer { settings.stop() }
        await settings.waitForLoad(atLeast: 1)
        let target = settings.loadCount + 1
        let updated = #"{"sidebar":{"sections":{"hidden":["recents"]}}}"#
        try Data(updated.utf8).write(to: file, options: .atomic)
        await settings.waitForLoad(atLeast: target)
        #expect(design.sidebarSections.projection.hiddenSections == ["recents"])
    }
}
