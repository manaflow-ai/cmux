import AppKit
@testable import CmuxNextApp
@testable import CmuxNextLayout
import Testing

/// A divider's catcher panel is made the first time the pointer comes to the divider, not when the layout lands
/// (first-5s bench, 2026-10-28). Cmd-Shift-N on the optimized v2.2.3 spent 386 ms (20 ms CPU) of the new window's
/// first turns in `DividerMousePanel.init`, a new NSPanel per divider hit area, made by `WindowOverlayLayer.evaluate`
/// while the window's first page window appeared; most dividers are never touched before the next layout.
@MainActor @Suite(.serialized) struct DividerCatcherLazyPanelTests {
    /// A visible window whose pages are child windows (the in-process default), far from any real pointer.
    static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 9000, y: 9000, width: 800, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    static let area = LayoutMouseArea(id: "d", rect: CGRect(x: 396, y: 0, width: 8, height: 500), resizesColumns: true)

    /// Areas the pointer has not reached get no panel: the layout landing makes none.
    @Test func aLandedLayoutMakesNoPanelForAnAreaThePointerIsNotIn() {
        let window = Self.window()
        defer { window.close() }
        let catchers = DividerMouseCatchers(window: window)
        defer { catchers.teardown() }

        catchers.update([Self.area], active: true)

        #expect(catchers.shownCount == 0, "a panel was made for a divider the pointer never came to")
        #expect(catchers.panelUpdates == 0)
        #expect(!(window.childWindows ?? []).contains { $0 is DividerMousePanel })
    }
}
