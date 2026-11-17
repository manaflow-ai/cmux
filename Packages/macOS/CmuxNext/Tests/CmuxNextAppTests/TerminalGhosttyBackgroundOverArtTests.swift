import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Ghostty color parity over a background picture (user, Nov 17: "colors between ghostty and cmux-next are definitely
/// still different, reproduce + fix + have tests so there will be no regressions").
///
/// Measured on cmux-lawrence-2 with the user's own configs (Ghostty 1.4.0, Monokai Classic, Menlo 12; cmux-next with
/// background art "laurence-mckinley" at 0.85): every palette, 256-color and truecolor cell, bold, inverse and the
/// glyphs' coverage match Ghostty to within 2/255. The one difference was the terminal's own background: Ghostty
/// draws `#272822`, cmux-next drew the window's 85 % tint over the picture (`#3a3d3b` on average, up to 25/255 off),
/// so dim text, glyph edges and every cell a program paints in the theme's background (palette 0, a TUI's panels)
/// stood out as dark patches on a lighter, picture-coloured ground.
///
/// A terminal over a picture now draws its Ghostty config's background at that config's own `background-opacity`
/// (1, Ghostty's default: solid, as Ghostty draws it); the picture shows in the sidebar, the chrome and the other
/// panes. `background-opacity` under 1 in the Ghostty config, or the user's `appearance.surfaces.terminal`, keep the
/// see-through terminal.
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

    @Test func overAPictureAnOpaqueGhosttyConfigsTerminalDrawsItsOwnBackground() throws {
        let expected = try Self.configBackground()
        try Self.withGhosttyOpacity(1) {
            let (window, _, host) = Self.host(over: Self.art)
            defer { window.close() }
            let backdrop = WindowBackdrop(host.themeScope.tokens, selection: host.themeScope.backdropSelection,
                                          tintOpacity: host.themeScope.backdropTintOpacity)
            try #require(!backdrop.panesPaintBackground, "the window over the picture is not see-through: the test no longer reaches the case")
            #expect(Self.rgba(host.layer?.backgroundColor) == expected,
                    "the terminal over a picture shows the picture instead of its Ghostty background")
            // A pane whose terminal is not made yet paints the same ground (SPLIT NEW PANE GROUND, m81).
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
