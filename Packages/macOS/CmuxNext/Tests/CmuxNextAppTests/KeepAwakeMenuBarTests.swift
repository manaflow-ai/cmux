import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextKeepAwake
@testable import CmuxNextSettings
import Foundation
import Testing

/// Keep-awake starts after the first frame (launch piece 7, cmuxterm-hq docs/design/launch-shell-first.md). A hold
/// taken before that, by the Keep Mac Awake action or the iPhone host, began with no menu bar to tell. `start` shows it.
@MainActor @Suite(.serialized)
struct KeepAwakeMenuBarTests {
    /// Its power-source monitor has an unretained context: never freed in this process (as CmdTTabListReadersTests).
    private static var kept: [KeepAwakeService] = []

    @Test func aHoldTakenBeforeStartShowsOnTheMenuBarOnceItStarts() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "keep-awake-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let keepAwake = KeepAwakeService()
        Self.kept.append(keepAwake)
        let menuBar = services.menuBarExtra

        keepAwake.toggleManual() // the Keep Mac Awake action, run before the first frame
        defer { keepAwake.toggleManual() } // ends the hold this test began
        #expect(menuBar.keepingAwake == nil, "fixture: nothing told the menu bar before start")

        keepAwake.start(settings: settings, store: services.daemon.store, menuBar: menuBar)
        #expect(menuBar.keepingAwake != nil, "the hold taken before start is not on the menu bar after it")
    }
}
