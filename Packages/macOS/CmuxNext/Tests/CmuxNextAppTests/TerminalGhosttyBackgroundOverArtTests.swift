import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Ghostty colors and the user's Opacity over a background picture (user, Nov 17: "colors between ghostty and cmux-next
/// are definitely still different"; then "background color is bad now for terminals, it's no longer transparent ... we
/// need to have both rich colors and proper transparency that respects user's settings").
///
/// c90b89beed41 answered the first report by painting a terminal over a picture solid whenever the Ghostty config
/// files left `background-opacity` at 1 (Ghostty's default), so the window Opacity the user set
/// (`appearance.backgroundOpacity`, the tint over the picture) stopped reaching terminals. A terminal over a picture
/// now shows it exactly as the window's tint shows it everywhere else: the host stays clear and the window root's one
/// sheet (the theme background at the Opacity) is the terminal's ground, whatever the config files' own opacity. At
/// Opacity 1 the window is opaque and the terminal paints the theme background solid. The user's
/// `appearance.surfaces.terminal` still wins. `TerminalTransparencyOverPictureTests` checks the composite in a whole
/// window.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalGhosttyBackgroundOverArtTests {
    private static let art = BackdropSelection.art(.dahlDresdenMoonlight)

    private static func rgba(_ color: CGColor?) -> [Int]? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    /// A terminal host in a window whose room shows `selection`, with `backgrounds`; the caller closes the window.
    private static func host(over selection: BackdropSelection?, backgrounds: SurfaceBackgrounds = .none)
        -> (window: NSWindow, scope: ThemeScope, host: TerminalHostView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scope = ThemeScope(level: .room)
        scope.pinBackdrop(selection.map(BackdropPin.selection) ?? .none)
        scope.setSurfaceBackgrounds(backgrounds)
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        scope.root(root)
        let host = TerminalHostView()
        host.frame = root.bounds
        root.addSubview(host)
        return (window, scope, host)
    }

    /// Runs `body` with the Ghostty config files' own `background-opacity` set to `opacity`, put back after.
    private static func withGhosttyOpacity<T>(_ opacity: Double, _ body: () throws -> T) rethrows -> T {
        let original = GhosttyConfigBackground.loaded
        defer { GhosttyConfigBackground.loaded = original }
        GhosttyConfigBackground.loaded = GhosttyConfigBackground(opacity: opacity, blur: original.blur)
        return try body()
    }

    private static func configBackground() throws -> [Int] {
        _ = GhosttyRuntime.shared
        let rgb = try #require(GhosttyRuntime.shared.themeColors?.background, "libghostty loaded no config")
        return [Int(rgb.r), Int(rgb.g), Int(rgb.b), 255]
    }

    /// The regression: with the config files' `background-opacity` at 1 the terminal still shows the picture at the
    /// window's Opacity (it painted its background solid).
    @Test func overAPictureAnOpaqueGhosttyConfigsTerminalStillShowsThePictureAtTheWindowsOpacity() throws {
        try Self.withGhosttyOpacity(1) {
            let (window, scope, host) = Self.host(over: Self.art)
            defer { window.close() }
            for opacity in [0.85, 0.6] {
                scope.pinBackdropTint(opacity)
                let backdrop = WindowBackdrop(host.themeScope.tokens, selection: host.themeScope.backdropSelection,
                                              tintOpacity: host.themeScope.backdropTintOpacity)
                try #require(!backdrop.panesPaintBackground && backdrop.tintOpacity == opacity,
                             "the window over the picture is not see-through at \(opacity): the test no longer reaches the case")
                #expect(host.layer?.backgroundColor == nil || Self.rgba(host.layer?.backgroundColor)?[3] == 0,
                        "at Opacity \(opacity) the terminal paints \(Self.rgba(host.layer?.backgroundColor) ?? []) over the picture")
                // A pane whose terminal is not made yet shows the same (SPLIT NEW PANE GROUND, m81).
                #expect(TerminalHostView.ground(theme: nil, in: host) == nil)
            }
        }
    }

    /// At Opacity 1 the window over the picture is opaque: the terminal paints its Ghostty background solid.
    @Test func overAPictureAtOpacity1TheTerminalDrawsItsGhosttyBackgroundSolid() throws {
        let expected = try Self.configBackground()
        try Self.withGhosttyOpacity(1) {
            let (window, scope, host) = Self.host(over: Self.art)
            defer { window.close() }
            scope.pinBackdropTint(1)
            #expect(Self.rgba(host.layer?.backgroundColor) == expected,
                    "at Opacity 1 the terminal paints \(Self.rgba(host.layer?.backgroundColor) ?? []), not \(expected)")
            #expect(Self.rgba(TerminalHostView.ground(theme: nil, in: host)) == expected)
        }
    }

    @Test func aSeeThroughGhosttyConfigKeepsThePictureBehindTheTerminal() throws {
        try Self.withGhosttyOpacity(0.85) {
            let (window, _, host) = Self.host(over: Self.art)
            defer { window.close() }
            #expect(host.layer?.backgroundColor == nil || Self.rgba(host.layer?.backgroundColor)?[3] == 0)
            #expect(TerminalHostView.ground(theme: nil, in: host) == nil)
        }
    }

    @Test func theUsersTerminalSurfaceBackgroundStillWins() throws {
        let ground = ThemeRGB(hex: 0x00FFFF)
        try Self.withGhosttyOpacity(1) {
            let (window, _, host) = Self.host(over: Self.art,
                                              backgrounds: SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(color: ground, opacity: 1)]))
            defer { window.close() }
            #expect(Self.rgba(host.layer?.backgroundColor) == [0, 255, 255, 255])
        }
    }

    /// Without a picture nothing changes: an opaque window paints the terminal's background as before.
    @Test func withoutAPictureAnOpaqueWindowIsUnchanged() throws {
        let expected = try Self.configBackground()
        try Self.withGhosttyOpacity(1) {
            let (window, _, host) = Self.host(over: nil)
            defer { window.close() }
            let backdrop = WindowBackdrop(host.themeScope.tokens, selection: host.themeScope.backdropSelection,
                                          tintOpacity: host.themeScope.backdropTintOpacity)
            guard backdrop.panesPaintBackground, GhosttyRuntime.shared.backgroundOpacity >= 1 else { return }
            #expect(Self.rgba(host.layer?.backgroundColor) == expected)
        }
    }
}
