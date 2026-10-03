import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Settings > Appearance > Window Background applies live: a write through
/// `SettingsController` (what the Opacity slider and Material menu do)
/// reaches every open main window with no relaunch. The path under test is
/// the app's own: `TerminalThemeSetting` puts the override into the
/// Ghostty config and reloads it, `ThemeBridge` feeds `ThemeStore`, and
/// each window's `WindowRootView` repaints its backdrop.
@MainActor @Suite(.serialized) struct WindowBackgroundLiveTests {
    private final class BlurLog {
        var radii: [ObjectIdentifier: Int] = [:]
    }

    private struct MainWindow {
        let window: NSWindow
        let root: WindowRootView
        let room: ThemeScope
    }

    /// A main window as `WindowController` builds it: backdrop, content
    /// view, room scope (no room theme, so it follows the config).
    private static func mainWindow(_ services: AppServices, blurs: BlurLog) -> MainWindow {
        let model = SidebarModel()
        let root = WindowRootView(sidebar: SidebarContainerView(model: model),
                                  rail: WindowRailView(model: model, registry: services.registry),
                                  reduceTransparency: { false },
                                  applyWindowBlur: { window, radius in blurs.radii[ObjectIdentifier(window)] = radius })
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let room = ThemeScope(level: .room)
        root.applyBackdrop(to: window)
        window.contentView = root
        room.adopt(window)
        return MainWindow(window: window, root: root, room: room)
    }

    /// Waits (bounded) for the settings observation task to apply a write.
    private static func until(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func write(_ settings: SettingsController, opacity: Double?, material: String?) async throws {
        try await settings.set(opacity.map(JSONValue.number) ?? .null, at: WindowBackgroundSetting.opacityPath)
        try await settings.set(material.map(JSONValue.string) ?? .null, at: WindowBackgroundSetting.materialPath)
        await settings.reload()
    }

    @Test func aSettingsWriteRepaintsEveryOpenMainWindow() async throws {
        _ = NSApplication.shared
        let runtime = GhosttyRuntime.shared
        try #require(runtime.app != nil, "libghostty did not start; the live path cannot run")
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-window-background-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)

        let services = AppServices(environment: AppEnvironment.current([:]))
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url)
        await settings.reload()
        ThemeBridge.start()
        let follower = TerminalThemeSetting()
        follower.follow(settings)

        let blurs = BlurLog()
        let windows = [Self.mainWindow(services, blurs: blurs), Self.mainWindow(services, blurs: blurs)]
        defer {
            for main in windows { main.window.close() }
            GhosttyRuntime.backgroundOverride = WindowBackgroundOverride()
            runtime.reloadConfig()
        }

        // Frosted at 50%: every window turns see-through with the tint at
        // the slider's value and a CGS blur radius behind it.
        try await Self.write(settings, opacity: 0.5, material: "frosted")
        await Self.until { ThemeStore.shared.tokens.backgroundOpacity == 0.5 }
        for main in windows {
            #expect(main.root.backdrop.material == .frosted)
            #expect(!main.window.isOpaque)
            #expect((main.window.backgroundColor?.alphaComponent ?? 1) < 0.01)
            let tint = try #require(main.root.backdropView.tintColor)
            #expect(abs(tint.alpha - 0.5) < 0.001)
            #expect((blurs.radii[ObjectIdentifier(main.window)] ?? 0) > 0, "frosted sets the window's blur radius")
        }

        // Dragging the slider: a new value repaints with no other change.
        try await Self.write(settings, opacity: 0.8, material: "frosted")
        await Self.until { ThemeStore.shared.tokens.backgroundOpacity == 0.8 }
        for main in windows {
            let tint = try #require(main.root.backdropView.tintColor)
            #expect(abs(tint.alpha - 0.8) < 0.001)
        }

        // Opaque with no blur: back to a solid window, blur radius cleared.
        try await Self.write(settings, opacity: 1, material: "none")
        await Self.until { ThemeStore.shared.tokens.backgroundOpacity == 1 }
        for main in windows {
            #expect(main.root.backdrop.material == .opaque)
            #expect(main.window.isOpaque)
            #expect(main.window.backgroundColor?.alphaComponent == 1)
            #expect(blurs.radii[ObjectIdentifier(main.window)] == 0, "the earlier frost is cleared")
        }
        withExtendedLifetime((follower, settings, windows)) {}
    }
}
