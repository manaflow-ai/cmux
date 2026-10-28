import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
@testable import CmuxNextTerminal
import Foundation
import Testing

/// Settings > Window Background with Material "Ghostty" (unset): opacity and blur come from the
/// Ghostty config. Moving Opacity through the Settings page repaints the window at once (the
/// slider's preview and its write) and turns Material into the explicit choice that matches
/// Ghostty's blur; resetting Opacity returns both rows to Ghostty.
@MainActor @Suite(.serialized) struct WindowBackgroundOpacityTests {
    /// The page's own writes: the bundled Settings page with a real gesture.
    static let gesture = PageCallContext(page: "cmux.settings", userGesture: true)
    static let opacityKey = "appearance.backgroundOpacity"

    static func ghostty(opacity: Double, blur: Int) -> GhosttyThemeColors {
        let gray = GhosttyThemeColors.RGB(r: 0x80, g: 0x80, b: 0x80)
        return GhosttyThemeColors(background: .init(r: 0x20, g: 0x22, b: 0x28), foreground: .init(r: 0xF0, g: 0xF0, b: 0xF0),
                                  palette: Array(repeating: gray, count: 16), selectionBackground: nil, selectionForeground: nil,
                                  cursor: nil, backgroundOpacity: opacity, backgroundBlur: blur)
    }

    /// The app's settings owner, its page provider and a real themed window, with Ghostty's
    /// config standing in for libghostty: a config reload applies `colors` with cmux.json's
    /// window background over them, as `ThemeBridge` does after `GhosttyRuntime.reloadConfig()`.
    struct Harness {
        let settings: SettingsController
        let terminal: TerminalThemeSetting
        let page: SettingsPageProvider
        let window: NSWindow
        let surface: WindowSurfaceView
        let url: URL
        let original: ThemeInput

        var alpha: CGFloat { window.backgroundColor.alphaComponent }
        var tintOpacity: Double { surface.backdrop(in: window).tintOpacity }
        var file: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        func tearDown() {
            window.close()
            GhosttyRuntime.backgroundOverride = WindowBackgroundOverride()
            GhosttyConfigBackground.loaded = GhosttyConfigBackground()
            ThemeScope.app.store.apply(original)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    func make(_ json: String = "{}", ghostty colors: GhosttyThemeColors = ghostty(opacity: 1, blur: 0)) async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-window-opacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()

        let original = ThemeScope.app.store.input
        GhosttyRuntime.backgroundOverride = WindowBackgroundOverride()
        // The config files' own values, as `GhosttyRuntime.loadConfig` records them.
        GhosttyConfigBackground.loaded = GhosttyConfigBackground(opacity: colors.backgroundOpacity, blur: colors.backgroundBlur)
        ThemeScope.app.store.apply(ThemeBridge.input(colors))
        let terminal = TerminalThemeSetting(backdropScope: ThemeScope(level: .room))
        terminal.reload = { ThemeScope.app.store.apply(ThemeBridge.input(colors, background: GhosttyRuntime.backgroundOverride)) }
        terminal.follow(settings)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let surface = WindowSurfaceView(content: NSView(), reduceTransparency: { false })
        ThemeScope.app.adopt(window)
        window.contentView = surface
        surface.paintWindowSurface(of: window)
        return Harness(settings: settings, terminal: terminal, page: SettingsPageProvider(settings: settings),
                       window: window, surface: surface, url: url, original: original)
    }

    /// Waits for the observers (`ObservationStream`) to see a change.
    func settle(until done: () -> Bool) async {
        for _ in 0..<400 where !done() { await Task.yield() }
    }

    /// Waits up to two seconds of wall time (a trailing deadline).
    func wait(until done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    func set(_ harness: Harness, _ key: String, _ value: JSONValue) async throws {
        _ = try await harness.page.call("cmux.settings.set", params: ["key": .string(key), "value": value], context: Self.gesture)
    }

    func reset(_ harness: Harness, _ key: String) async throws {
        _ = try await harness.page.call("cmux.settings.reset", params: ["key": .string(key)], context: Self.gesture)
    }

    @Test func settingOpacityInGhosttyModeRepaintsTheWindowAndLeavesGhostty() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        #expect(harness.settings.snapshot.windowBackground.material == nil)
        #expect(harness.window.isOpaque)
        #expect(harness.alpha == 1)

        _ = try await harness.page.call("cmux.settings.set", params: ["key": .string(Self.opacityKey), "value": 0.35],
                                        context: Self.gesture)
        await settle { !harness.window.isOpaque }

        #expect(!harness.window.isOpaque)
        #expect(harness.alpha < 1)
        #expect(abs(harness.tintOpacity - 0.35) < 0.001)
        // Material is no longer Ghostty: it names the choice Ghostty's blur gave (none here).
        #expect(harness.settings.snapshot.windowBackground.opacity == 0.35)
        #expect(harness.settings.snapshot.windowBackground.material == .unblurred)
    }

    /// The slider's preview repaints the window on every step, with no write and no Material
    /// switch; ending it restores Ghostty's opaque window.
    @Test func theOpacitySlidersPreviewRepaintsTheWindowLive() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        #expect(harness.window.isOpaque)

        _ = try await harness.page.call("cmux.settings.preview", params: ["key": .string(Self.opacityKey), "value": 0.5],
                                        context: Self.gesture)
        await settle { !harness.window.isOpaque }
        #expect(!harness.window.isOpaque)
        #expect(abs(harness.tintOpacity - 0.5) < 0.001)

        _ = try await harness.page.call("cmux.settings.preview", params: ["key": .string(Self.opacityKey), "value": 0.35],
                                        context: Self.gesture)
        await settle { abs(harness.tintOpacity - 0.35) < 0.001 }
        #expect(abs(harness.tintOpacity - 0.35) < 0.001)
        #expect(!harness.file.contains("backgroundOpacity"))

        _ = try await harness.page.call("cmux.settings.preview.end", params: [:], context: Self.gesture)
        await settle { harness.window.isOpaque }
        #expect(harness.window.isOpaque)
        #expect(harness.alpha == 1)
    }

    /// Reset (the row's ↺) returns Material to Ghostty and the window to Ghostty's values.
    @Test func resettingOpacityReturnsMaterialToGhostty() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        _ = try await harness.page.call("cmux.settings.set", params: ["key": .string(Self.opacityKey), "value": 0.35],
                                        context: Self.gesture)
        await settle { !harness.window.isOpaque }
        #expect(!harness.window.isOpaque)

        _ = try await harness.page.call("cmux.settings.reset", params: ["key": .string(Self.opacityKey)], context: Self.gesture)
        await settle { harness.window.isOpaque }

        #expect(harness.settings.snapshot.windowBackground == WindowBackgroundOverride())
        #expect(!harness.file.contains("backgroundBlur"))
        #expect(!harness.file.contains("backgroundOpacity"))
        #expect(harness.window.isOpaque)
        #expect(harness.alpha == 1)
    }

    /// In Ghostty mode the Opacity row reads Ghostty's own value, and a write keeps Ghostty's
    /// blur as the explicit material (a blur radius is Frosted).
    @Test func ghosttyModeReadsGhosttysOpacityAndKeepsItsBlur() async throws {
        // First: the app's services may load the machine's own Ghostty config, which records its values.
        let services = AppServices(environment: AppEnvironment.current([:]))
        let harness = try await make(ghostty: Self.ghostty(opacity: 0.9, blur: 20))
        defer { harness.tearDown() }
        #expect(services.settingsWindow.pageDerivedNumbers()[Self.opacityKey] == .number(0.9))

        _ = try await harness.page.call("cmux.settings.set", params: ["key": .string(Self.opacityKey), "value": 0.5],
                                        context: Self.gesture)
        await settle { abs(harness.tintOpacity - 0.5) < 0.001 }
        #expect(abs(harness.tintOpacity - 0.5) < 0.001)
        #expect(harness.settings.snapshot.windowBackground.material == .frosted)
        #expect(harness.surface.backdrop(in: harness.window).material == .frosted)
    }

    /// A Material the user chose survives Opacity's reset: only Opacity goes back to Ghostty's.
    @Test func resettingOpacityKeepsAChosenMaterial() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        try await set(harness, "appearance.backgroundBlur", "glass")
        try await set(harness, Self.opacityKey, 0.5)
        #expect(harness.settings.snapshot.windowBackground == WindowBackgroundOverride(opacity: 0.5, material: .glass))

        try await reset(harness, Self.opacityKey)
        #expect(harness.settings.snapshot.windowBackground == WindowBackgroundOverride(material: .glass))
        #expect(harness.file.contains("glass"))
    }

    /// Material's reset (back to "Ghostty") takes Opacity back to Ghostty's too.
    @Test func resettingMaterialRemovesOpacity() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        try await set(harness, "appearance.backgroundBlur", "frosted")
        try await set(harness, Self.opacityKey, 0.6)
        #expect(harness.settings.snapshot.windowBackground == WindowBackgroundOverride(opacity: 0.6, material: .frosted))

        try await reset(harness, "appearance.backgroundBlur")
        #expect(harness.settings.snapshot.windowBackground == WindowBackgroundOverride())
        #expect(!harness.file.contains("backgroundOpacity"))
    }

    /// The flip names the material of Ghostty's own blur, read from the config files, even when
    /// the window's resolved blur differs (a Material preview in flight).
    @Test func theFlipReadsGhosttysOwnBlur() async throws {
        let harness = try await make(ghostty: Self.ghostty(opacity: 1, blur: -1))
        defer { harness.tearDown() }
        // The resolved blur says frosted (a material preview); Ghostty's own is glass.
        _ = try await harness.page.call("cmux.settings.preview", params: ["key": "appearance.backgroundBlur", "value": "frosted"],
                                        context: Self.gesture)
        await settle { ThemeScope.app.store.input.backgroundBlur != -1 }
        #expect(ThemeScope.app.store.input.backgroundBlur != -1)
        try await set(harness, Self.opacityKey, 0.5)
        #expect(harness.settings.snapshot.windowBackground.material == .glass)
        _ = try await harness.page.call("cmux.settings.preview.end", params: [:], context: Self.gesture)

        try await reset(harness, Self.opacityKey)
        #expect(harness.settings.snapshot.windowBackground == WindowBackgroundOverride())
    }

    /// Every slider step repaints the window, while the Ghostty config reloads once after the
    /// steps stop (and at once when the window turns translucent or opaque).
    @Test func sliderStepsRepaintEachStepAndCoalesceTheReload() async throws {
        let harness = try await make()
        defer { harness.tearDown() }
        var reloads = 0
        let reload = harness.terminal.reload
        harness.terminal.reload = { reloads += 1; reload() }
        // The app's 60 ms is a drag's pace: a loaded test host can take longer between two steps
        // and reload mid-drag (cx-7l2nc, macOS 27). A second still coalesces and stays inside `wait`.
        harness.terminal.reloadDelay = .seconds(1)

        _ = try await harness.page.call("cmux.settings.preview", params: ["key": .string(Self.opacityKey), "value": 0.5],
                                        context: Self.gesture)
        await settle { !harness.window.isOpaque }
        #expect(!harness.window.isOpaque)
        let afterFirst = reloads
        for step in [0.45, 0.4, 0.35] {
            _ = try await harness.page.call("cmux.settings.preview", params: ["key": .string(Self.opacityKey), "value": .number(step)],
                                            context: Self.gesture)
            await settle { abs(harness.tintOpacity - step) < 0.001 }
            #expect(abs(harness.tintOpacity - step) < 0.001)
        }
        #expect(reloads == afterFirst)

        try await wait { reloads > afterFirst }
        #expect(reloads == afterFirst + 1)
        #expect(abs(harness.tintOpacity - 0.35) < 0.001)
        _ = try await harness.page.call("cmux.settings.preview.end", params: [:], context: Self.gesture)
        await settle { harness.window.isOpaque }
        #expect(harness.window.isOpaque)
    }

    /// Leo's report: dragging Opacity "reverts to Ghostty". Neither the slider's preview steps nor
    /// its write touch the theme or the background picture: both stay what cmux.json names, and
    /// the Ghostty override keeps the theme through the reloads the drag causes.
    @Test func draggingOpacityKeepsTheThemeAndTheBackground() async throws {
        let work = "van-gogh-starry-night"
        let harness = try await make(#"{"appearance": {"theme": "Dracula", "background": "\#(work)"}}"#)
        defer { harness.tearDown() }
        #expect(harness.settings.snapshot.appTheme == "Dracula")
        #expect(harness.settings.snapshot.backdropSelection?.id == work)

        for step in [0.6, 0.55, 0.5, 0.45] {
            _ = try await harness.page.call("cmux.settings.preview", params: ["key": .string(Self.opacityKey), "value": .number(step)],
                                            context: Self.gesture)
            await settle { abs(harness.tintOpacity - step) < 0.001 }
            #expect(harness.settings.applied.appTheme == "Dracula")
            #expect(harness.settings.applied.backdropSelection?.id == work)
            #expect(GhosttyRuntime.themeOverride == "Dracula")
        }
        try await set(harness, Self.opacityKey, 0.45)
        _ = try await harness.page.call("cmux.settings.preview.end", params: ["key": .string(Self.opacityKey)], context: Self.gesture)
        await settle { harness.settings.previewingKey == nil }

        #expect(harness.settings.snapshot.windowBackground.opacity == 0.45)
        #expect(harness.settings.snapshot.appTheme == "Dracula")
        #expect(harness.settings.snapshot.backdropSelection?.id == work)
        #expect(GhosttyRuntime.themeOverride == "Dracula")
        #expect(harness.file.contains("Dracula"))
        #expect(harness.file.contains(work))
    }

    /// Over a background picture the unset slider sits on the tint the window shows (the work's
    /// own, above the legibility floor), not on the theme's opaque 100%: the click that used to
    /// jump from 100% now starts where the window is.
    @Test func overArtTheUnsetSliderSitsOnTheShownTint() throws {
        let scope = ThemeScope(level: .room)
        #expect(scope.shownWindowOpacity == scope.input.backgroundOpacity)
        let work = try #require(BackdropSelection(id: "van-gogh-starry-night"))
        scope.setBackdropSelection(work)
        let shown = WindowBackdrop(scope.tokens, art: scope.backdropArt, selection: scope.backdropSelection,
                                   tuning: scope.appearanceTuning, tintOpacity: scope.backdropTintOpacity)
        #expect(!shown.isOpaque)
        #expect(scope.shownWindowOpacity == shown.tintOpacity)
        #expect(scope.shownWindowOpacity < 1)
    }
}
