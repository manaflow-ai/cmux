import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The automatic light/dark theme switch over a background picture (Chief, Nov 17, after "colors between ghostty
/// and cmux-next are definitely still different"): with a `light:A,dark:B` theme, a terminal over a picture at Opacity 1
/// (an opaque window: `TerminalGhosttyBackgroundOverArtTests`) draws its Ghostty background solid, so when the app's
/// appearance flips, that ground must turn to the other variant's background with the cells, as Ghostty's window does.
/// A stale ground shows the old variant's background beside and under every cell. Under 1 the terminal shows the
/// window's sheet, which follows the app's colors (`TerminalTransparencyOverPictureTests`).
///
/// The test flips only this process's appearance (`NSApp.appearance`), never the Mac's: the Ghostty runtime follows
/// `NSApp.effectiveAppearance` (`GhosttyRuntime.applyColorScheme`), Ghostty applies the pair's other variant and
/// answers with the config it applied (`GHOSTTY_ACTION_CONFIG_CHANGE`, `GhosttyRuntime.configDidChange`). Nothing of
/// the app's theme store is wired here, so the host must follow the config by itself.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalGroundFollowsColorSchemeTests {
    /// The app's default pair, copied by path to a short folder: a test process has no Ghostty resources folder to
    /// find themes by name in, and a theme spec holds at most `ThemeSpec.maximumLength` characters.
    private static func pair() throws -> (light: String, dark: String, folder: URL) {
        let themes = AANestedGroupsGalleryTests.repoRoot.appending(path: "Resources/ghostty/themes")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gt-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let light = folder.appending(path: "L"), dark = folder.appending(path: "D")
        try FileManager.default.copyItem(at: themes.appending(path: "Apple System Colors Light"), to: light)
        try FileManager.default.copyItem(at: themes.appending(path: "Apple System Colors"), to: dark)
        return (light.path, dark.path, folder)
    }

    private static func rgba(_ color: CGColor?) -> [Int]? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    /// The background `theme` alone resolves to, opaque.
    private static func background(_ theme: String) throws -> [Int] {
        let colors = try #require(GhosttyRuntime.themeColors(configText: "theme = \(theme)"), "no colors for \(theme)")
        return [Int(colors.background.r), Int(colors.background.g), Int(colors.background.b), 255]
    }

    /// Polls `condition` on the main actor for up to `seconds`; true once it holds.
    private static func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func overAPictureTheGroundTurnsWithTheAppsAppearance() async throws {
        let app = NSApplication.shared
        _ = GhosttyRuntime.shared
        let pair = try Self.pair()
        defer { try? FileManager.default.removeItem(at: pair.folder) }
        let light = try Self.background(pair.light), dark = try Self.background(pair.dark)
        try #require(light != dark, "the pair's variants share a background: the test would prove nothing")

        let (originalTheme, originalAppearance, originalOpacity) = (GhosttyRuntime.themeOverride, app.appearance, GhosttyConfigBackground.loaded)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            app.appearance = originalAppearance
            GhosttyConfigBackground.loaded = originalOpacity
            GhosttyRuntime.themeOverride = originalTheme
            GhosttyRuntime.shared.reloadConfig()
        }
        GhosttyConfigBackground.loaded = GhosttyConfigBackground(opacity: 1, blur: originalOpacity.blur)
        app.appearance = NSAppearance(named: .aqua)
        let spec = "light:\(pair.light),dark:\(pair.dark)"
        try #require(ThemeSpec(spec) != nil && GhosttyRuntime.themeOverrideLine(spec) != nil, "the pair's spec is refused: \(spec)")
        GhosttyRuntime.themeOverride = spec
        GhosttyRuntime.shared.reloadConfig()

        let scope = ThemeScope(level: .room)
        scope.pinBackdrop(.selection(.art(.dahlDresdenMoonlight)))
        scope.pinBackdropTint(1)
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        scope.root(root)
        let host = TerminalHostView()
        host.frame = root.bounds
        root.addSubview(host)
        window.orderFrontRegardless()

        func config() -> [Int]? {
            GhosttyRuntime.shared.themeColors.map { [Int($0.background.r), Int($0.background.g), Int($0.background.b), 255] }
        }
        try #require(await Self.eventually { config() == light }, "the light app never loaded the pair's light variant: \(config() ?? [])")
        #expect(await Self.eventually { Self.rgba(host.layer?.backgroundColor) == light },
                "light: the terminal over the picture paints \(Self.rgba(host.layer?.backgroundColor) ?? []), not the light variant's \(light)")

        for (appearance, expected, name) in [(NSAppearance.Name.darkAqua, dark, "dark"), (.aqua, light, "light again")] {
            app.appearance = NSAppearance(named: appearance)
            try #require(await Self.eventually { config() == expected },
                         "\(name): the Ghostty config never switched variant: \(config() ?? []), expected \(expected)")
            #expect(await Self.eventually { Self.rgba(host.layer?.backgroundColor) == expected },
                    "\(name): the terminal over the picture still paints \(Self.rgba(host.layer?.backgroundColor) ?? []), not \(expected)")
            #expect(Self.rgba(TerminalHostView.ground(theme: nil, in: host)) == expected,
                    "\(name): a pane waiting for its terminal paints another ground than the terminal")
        }
    }
}
