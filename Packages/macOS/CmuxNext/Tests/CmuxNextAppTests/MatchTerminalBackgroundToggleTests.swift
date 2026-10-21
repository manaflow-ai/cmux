import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Toggle Match Terminal Background (`palette.toggleMatchTerminalBackground`,
/// `cmux sidebar toggle-match-terminal-background`): the sidebar either
/// takes the main pane's (terminal's) background or is shaded apart from it.
/// The action flips `appearance.sidebarSurface` in cmux.json between
/// "separate" and "same", so Settings > Sidebar Background shows the choice.
@MainActor @Suite(.serialized) struct MatchTerminalBackgroundToggleTests {
    @Test func toggleFlipsTheSidebarSurfaceSetting() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-match-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        services.settings = settings
        await settings.reload()
        #expect(services.registry.unavailableReason(for: "palette.toggleMatchTerminalBackground") == nil,
                "Toggle Match Terminal Background is still greyed out")

        func saved() -> String? {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (root["appearance"] as? [String: Any])?["sidebarSurface"] as? String
        }
        func until(_ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }

        // The default matches the terminal ("same"): the first toggle shades the sidebar apart.
        #expect(services.registry.perform("palette.toggleMatchTerminalBackground", invocation: ActionInvocation()))
        await until { saved() == "separate" && SidebarSurfaceSetting.effective(in: settings.snapshot) == .separate }
        #expect(saved() == "separate")
        #expect(services.registry.perform("palette.toggleMatchTerminalBackground", invocation: ActionInvocation()))
        await until { saved() == "same" }
        #expect(saved() == "same")
    }
}
