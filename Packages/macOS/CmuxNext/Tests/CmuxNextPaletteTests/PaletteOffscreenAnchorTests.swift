import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// NIGHTLY, Lawrence 2026-11-16 ("cmd shift p ... opened in bottom left instead of center"): a Chromium page an agent
/// drove in the background had the keys. Its window is a child of the agent render window, which lies left of and
/// below every screen; Cmd-Shift-P walked up to that window and clamped the palette to the screen's bottom-left corner.
@MainActor @Suite(.closesItsWindows, .enabled(if: !NSScreen.screens.isEmpty))
struct PaletteOffscreenAnchorTests {
    /// A window under a window off every screen is no anchor: the palette opens top-centered on the screen.
    @Test func aWindowUnderAWindowOffEveryScreenDoesNotPinThePaletteToAScreenCorner() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let screens = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        // Where `AgentRenderWindows.frame(for:screens:)` puts a render window.
        let offscreen = NSRect(x: screens.minX - 1280 - 10_000, y: screens.minY - 800 - 10_000, width: 1280, height: 800)
        let render = NSWindow(contentRect: offscreen, styleMask: .borderless, backing: .buffered, defer: true)
        defer { render.closeAfterTest() }
        let page = NSWindow(contentRect: offscreen, styleMask: .borderless, backing: .buffered, defer: true)
        render.addChildWindow(page, ordered: .above)
        defer { page.closeAfterTest() }
        let palette = PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }

        palette.show(.commands, relativeTo: page)

        let frame = try #require(palette.visiblePanel?.frame)
        let visible = screen.visibleFrame
        #expect(abs(frame.midX - visible.midX) <= 1, "the palette is not centered on the screen: \(frame) in \(visible)")
        #expect(frame.minY > visible.minY, "the palette sits on the screen's bottom edge: \(frame) in \(visible)")
    }
}
