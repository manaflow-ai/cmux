import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTerminal
import CmuxTheme
import Foundation
import Testing

/// A terminal over a background picture shows it at the user's own Opacity, with the Ghostty theme's exact colors
/// (user, Nov 17: "background color is bad now for terminals, it's no longer transparent ... we need to have both rich
/// colors and proper transparency that respects user's settings, and tests for both"; "we need to make sure custom bgs
/// work properly").
///
/// c90b89beed41 painted the terminal solid over any picture whenever the Ghostty config FILES left
/// `background-opacity` at 1 (Ghostty's default, which nearly everyone has), so the window Opacity the user set
/// (`appearance.backgroundOpacity`, the tint over the picture) no longer reached terminals. Here a whole window
/// (`WindowRootView`) shows a picture (bundled art, and the person's own image file) at a window Opacity under 1, and
/// a terminal host sits in its main pane. What every layer paints under the terminal, composited in drawing order over
/// a fixed stand-in for the picture (`ChromeLayerColorTests.painted`), must be the Ghostty background at the Opacity
/// once: `w * T + (1 - w) * P`, no solid ground and no second tint. Changing the Opacity live moves it; Opacity 1 is
/// solid `T`, exactly. Dark and light themes.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalTransparencyOverPictureTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        /// The Ghostty theme (a file of `Resources/ghostty/themes`).
        let theme: String
        let dark: Bool
        /// Whether the picture is the person's own image file (`BackdropSelection.file`) instead of bundled art.
        let ownImage: Bool
        var testDescription: String { name }
    }

    nonisolated static let cases = [
        Case(name: "dark, bundled art", theme: "Monokai Classic", dark: true, ownImage: false),
        Case(name: "light, bundled art", theme: "Apple System Colors Light", dark: false, ownImage: false),
        Case(name: "dark, own image", theme: "Apple System Colors", dark: true, ownImage: true),
    ]

    /// The largest channel step allowed, 0...255: rounding of the layers' 8-bit colors.
    nonisolated static let tolerance = 1

    static func bytes(_ color: ThemeRGB) -> [Int] {
        [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
    }

    static func close(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
        zip(bytes(a), bytes(b)).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// A one-color PNG in a fresh folder: the person's own background picture.
    static func ownImage() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "tt-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "own.png")
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor(srgbRed: 0.9, green: 0.3, blue: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        image.unlockFocus()
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// Runs `body` with the Ghostty runtime on `theme`, the app's colors fed from it as the app does
    /// (`ThemeBridge`), the config files' own `background-opacity` at 1, `selection` as the window's picture and
    /// no window Opacity; all put back after.
    static func inCase<T>(_ item: Case, selection: BackdropSelection,
                          _ body: @MainActor (_ terminalBackground: ThemeRGB) async throws -> T) async throws -> T {
        _ = NSApplication.shared
        let runtime = GhosttyRuntime.shared
        let themes = AANestedGroupsGalleryTests.repoRoot.appending(path: "Resources/ghostty/themes")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "tt-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let theme = folder.appending(path: "T")
        try FileManager.default.copyItem(at: themes.appending(path: item.theme), to: theme)
        let original = (theme: GhosttyRuntime.themeOverride, opacity: GhosttyConfigBackground.loaded,
                        input: ThemeScope.app.store.input, selection: ThemeScope.app.backdropSelection)
        defer {
            ThemeScope.app.setWindowBackdropTint(nil)
            ThemeScope.app.setBackdropSelection(original.selection)
            GhosttyRuntime.themeOverride = original.theme
            runtime.reloadConfig()
            GhosttyConfigBackground.loaded = original.opacity
            _ = ThemeScope.app.store.apply(original.input)
            try? FileManager.default.removeItem(at: folder)
        }
        GhosttyRuntime.themeOverride = theme.path
        runtime.reloadConfig()
        GhosttyConfigBackground.loaded = GhosttyConfigBackground(opacity: 1, blur: 0)
        let colors = try #require(runtime.themeColors, "libghostty loaded no config for \(item.theme)")
        _ = ThemeScope.app.store.apply(ThemeBridge.input(colors))
        ThemeScope.app.setBackdropSelection(selection)
        let background = ThemeRGB(r: colors.background.r, g: colors.background.g, b: colors.background.b)
        return try await body(background)
    }

    /// A terminal host filling the window's main pane.
    static func terminal(in root: WindowRootView) -> TerminalHostView {
        let host = TerminalHostView()
        host.frame = root.contentHost.bounds
        host.autoresizingMask = [.width, .height]
        root.contentHost.addSubview(host)
        return host
    }

    /// What the window shows under the middle of `host`.
    static func under(_ host: TerminalHostView, in root: WindowRootView) -> ThemeRGB {
        let point = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: root)
        return ChromeLayerColorTests.painted(at: point, in: root)
    }

    @Test(arguments: cases)
    func aTerminalOverAPictureShowsItAtTheUsersOpacityAndFollowsItLive(_ item: Case) async throws {
        let image = item.ownImage ? try Self.ownImage() : nil
        defer { image.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        let selection: BackdropSelection = image.map { .file(path: $0.path) } ?? .art(.vanGoghStarryNight)
        try await Self.inCase(item, selection: selection) { ground in
            let (window, root) = ChromeLayerColorTests.openRoot(dark: item.dark)
            defer { window.close() }
            let host = Self.terminal(in: root)
            let picture = ChromeLayerColorTests.pictureStandIn
            for opacity in [0.85, 0.6, 1.0] {
                ThemeScope.app.setWindowBackdropTint(opacity)
                root.themeDidChange()
                let expected = ground.withAlpha(opacity).composited(over: picture.withAlpha(1))
                var last = Self.under(host, in: root)
                await ChromeLayerColorTests.settle(root) {
                    let now = Self.under(host, in: root)
                    defer { last = now }
                    return now == last && (opacity >= 1 || !root.backdropView.artView.isHidden)
                }
                if opacity < 1 {
                    try #require(!root.backdropView.artView.isHidden, "\(item.name): the window never showed its picture")
                }
                let got = Self.under(host, in: root)
                let painters = ChromeLayerColorTests.painters(at: host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: root),
                                                              in: root).joined(separator: " | ")
                #expect(Self.close(got, expected),
                        "\(item.name) at Opacity \(opacity): under the terminal \(Self.bytes(got)), expected \(Self.bytes(expected)) (the theme background \(Self.bytes(ground)) at \(opacity) over the picture), painted by: \(painters)")
                // A pane waiting for its terminal (a split's stand-in) paints the same ground.
                let standIn = TerminalHostView.ground(theme: nil, in: host)
                if opacity < 1 {
                    #expect(standIn == nil, "\(item.name) at \(opacity): a waiting pane paints a ground over the picture")
                } else {
                    #expect(standIn.flatMap { ChromeLayerColorTests.rgb($0, opacity: 1) }.map { Self.close($0, ground) } == true,
                            "\(item.name) at 1: a waiting pane's ground is not the theme background")
                }
            }
        }
    }

    /// The user's own terminal color (`appearance.surfaces.terminal`) more opaque than the window: the terminal shows
    /// that color at its own opacity over the picture, once (`w` of the window's tint under it is compensated).
    @Test(arguments: [cases[0], cases[1]])
    func aCustomTerminalColorOverAPictureShowsAtItsOwnOpacity(_ item: Case) async throws {
        try await Self.inCase(item, selection: .art(.vanGoghStarryNight)) { _ in
            let color = ThemeRGB(hex: 0x1E3A5F)
            let original = ThemeScope.app.surfaceBackgrounds
            defer { ThemeScope.app.setSurfaceBackgrounds(original) }
            let (window, root) = ChromeLayerColorTests.openRoot(dark: item.dark)
            defer { window.close() }
            let host = Self.terminal(in: root)
            ThemeScope.app.setWindowBackdropTint(0.7)
            for own in [0.95, 1.0] {
                ThemeScope.app.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(color: color, opacity: own)]))
                root.themeDidChange()
                await ChromeLayerColorTests.settle(root) { !root.backdropView.artView.isHidden }
                let expected = color.withAlpha(own).composited(over: ChromeLayerColorTests.pictureStandIn.withAlpha(1))
                let got = Self.under(host, in: root)
                #expect(Self.close(got, expected),
                        "\(item.name): terminal color at \(own) over a window at 0.7: \(Self.bytes(got)), expected \(Self.bytes(expected))")
            }
        }
    }
}
