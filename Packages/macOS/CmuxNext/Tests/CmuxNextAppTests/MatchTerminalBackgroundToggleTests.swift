import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// Match Terminal Background (`palette.toggleMatchTerminalBackground`,
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
                "Match Terminal Background is still greyed out")

        func saved() -> String? {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (root["appearance"] as? [String: Any])?["sidebarSurface"] as? String
        }
        /// Whether cmux.json is there and parses as an object, so a missing or unreadable file never passes for "the key is absent".
        func fileParses() -> Bool {
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) else { return false }
            return root is [String: Any]
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
        // "same" is the default: the write removes the key (#38119), so cmux.json keeps no copy.
        await until { fileParses() && saved() == nil && SidebarSurfaceSetting.effective(in: settings.snapshot) == .same }
        #expect(fileParses(), "cmux.json is missing or does not parse")
        #expect(saved() == nil, "the default leaves cmux.json")
        #expect(SidebarSurfaceSetting.effective(in: settings.snapshot) == .same)
    }

    /// The palette row reads the state its run asked for at once, while cmux.json is still being
    /// written, and the open palette reads its rows again when the write lands (Leo 2026-11-07: the
    /// row flips in place). Before, the row kept its old state until the next open.
    @Test func thePaletteStateFollowsTheRunBeforeTheWriteLands() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-match-bg-state-\(UUID().uuidString)")
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
        let registry = services.registry
        final class Count { var value = 0 }
        let reloads = Count()
        registry.paletteStateDidChange = { reloads.value += 1 }
        func state() -> Bool? { registry.action(for: "palette.toggleMatchTerminalBackground")?.paletteState?() }

        #expect(state() == true, "the default matches the terminal")
        #expect(registry.perform("palette.toggleMatchTerminalBackground", invocation: ActionInvocation()))
        #expect(state() == false, "the row reads the new state in the run's own turn")
        let deadline = ContinuousClock.now + .seconds(10)
        while reloads.value == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(reloads.value == 1, "the palette is told once the write landed")
        #expect(SidebarSurfaceSetting.effective(in: settings.snapshot) == .separate)
        #expect(state() == false, "the stored value agrees")
    }

    /// Two runs before the first write lands end where they started: the second flips from the state the
    /// first asked for, and its write lands after the first one's.
    @Test func twoQuickRunsEndWhereTheyStarted() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-match-bg-twice-\(UUID().uuidString)")
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
        let registry = services.registry
        final class Count { var value = 0 }
        let reloads = Count()
        registry.paletteStateDidChange = { reloads.value += 1 }
        func state() -> Bool? { registry.action(for: "palette.toggleMatchTerminalBackground")?.paletteState?() }

        #expect(registry.perform("palette.toggleMatchTerminalBackground", invocation: ActionInvocation()))
        #expect(registry.perform("palette.toggleMatchTerminalBackground", invocation: ActionInvocation()))
        #expect(state() == true, "two flips read as the start")
        let deadline = ContinuousClock.now + .seconds(10)
        while reloads.value == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(SidebarSurfaceSetting.effective(in: settings.snapshot) == .same, "the last write is the second run's")
        #expect(state() == true)
    }
}
