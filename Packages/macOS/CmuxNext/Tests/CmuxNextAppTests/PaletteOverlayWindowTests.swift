import AppKit
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// The palette's focus overlay goes on the window the panel opens over
/// (#4303: "the palette UI is invoked, but the next character typed lands in
/// the terminal"). The overlay used to go on `windows.active`, which is the
/// window an input event came from, else the key window's, else the last
/// active one: none of those is the window the palette parents to when the
/// two disagree. The overlay then sat on a window the palette was not over,
/// and the window under the panel kept an empty overlay stack, so it went on
/// treating its terminal as the keyboard target (input-spec.md W5, W6, F1).
@MainActor @Suite(.serialized)
struct PaletteOverlayWindowTests {
    @Test func theOverlayGoesOnTheWindowThePaletteOpensOver() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let over = try #require(services.windows.openWindow(workspaces: ["palette-overlay-over"]))
        let elsewhere = try #require(services.windows.openWindow(workspaces: ["palette-overlay-elsewhere"]))
        defer {
            services.palette.hide()
            for controller in services.windows.controllers { controller.window?.close() }
        }
        let overWindow = try #require(over.window)
        // The active window is the other one, as it is for a press in one
        // window while another holds the keys.
        services.keyWindowSource = { elsewhere.window }
        try #require(services.windows.active === elsewhere, "the active window is not the other one")

        services.palette.show(.commands, relativeTo: overWindow)

        #expect(over.focus.state.overlays.contains(.palette),
                "the window the palette opened over has no palette overlay")
        #expect(!elsewhere.focus.state.overlays.contains(.palette),
                "the palette overlay landed on a window the palette is not over")

        services.palette.hide()
        #expect(!over.focus.state.overlays.contains(.palette), "the overlay outlived the palette")
    }
}
