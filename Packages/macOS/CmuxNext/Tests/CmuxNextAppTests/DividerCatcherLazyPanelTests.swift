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

    /// The first move into an area makes its panel, over the area; a move elsewhere makes none.
    @Test func theFirstMoveIntoAnAreaMakesItsPanel() throws {
        let window = Self.window()
        defer { window.close() }
        let catchers = DividerMouseCatchers(window: window, pointerLocation: { .zero })
        defer { catchers.teardown() }
        let other = LayoutMouseArea(id: "e", rect: CGRect(x: 0, y: 246, width: 800, height: 8), resizesColumns: false)
        catchers.update([Self.area, other], active: true)
        #expect(catchers.wantsPointer)

        let screen = window.convertToScreen(Self.area.rect)
        #expect(!catchers.pointerMoved(toScreen: CGPoint(x: screen.minX - 40, y: screen.midY + 100)), "a move outside every area")
        #expect(catchers.shownCount == 0)
        #expect(catchers.pointerMoved(toScreen: CGPoint(x: screen.midX, y: screen.maxY - 10)))
        #expect(catchers.shownCount == 1)
        #expect(catchers.framesInWindow["d"] == Self.area.rect, "the panel covers its area: \(catchers.framesInWindow)")
        #expect(catchers.wantsPointer, "the other area still waits")

        let otherScreen = window.convertToScreen(other.rect)
        #expect(catchers.pointerMoved(toScreen: CGPoint(x: otherScreen.minX + 10, y: otherScreen.midY)))
        #expect(catchers.shownCount == 2)
        #expect(!catchers.wantsPointer, "every area has its panel: moves cost one check")
        #expect(!catchers.pointerMoved(toScreen: CGPoint(x: screen.midX, y: screen.midY)), "a panel is made once")
    }

    /// An area that appears under a pointer that does not move gets its panel at once: a click needs no move first.
    @Test func anAreaUnderAStillPointerGetsItsPanelAtOnce() {
        let window = Self.window()
        defer { window.close() }
        let screen = window.convertToScreen(Self.area.rect)
        let catchers = DividerMouseCatchers(window: window, pointerLocation: { CGPoint(x: screen.midX, y: screen.midY) })
        defer { catchers.teardown() }

        catchers.update([Self.area], active: true)

        #expect(catchers.shownCount == 1)
        #expect(!catchers.wantsPointer)
    }

    /// A panel once made follows its area when the layout moves it, and goes with it; no page window, no panel.
    @Test func aMadePanelFollowsItsAreaAndGoesWithIt() {
        let window = Self.window()
        defer { window.close() }
        let catchers = DividerMouseCatchers(window: window, pointerLocation: { .zero })
        defer { catchers.teardown() }
        catchers.update([Self.area], active: true)
        let screen = window.convertToScreen(Self.area.rect)
        catchers.pointerMoved(toScreen: CGPoint(x: screen.midX, y: screen.midY))

        var moved = Self.area
        moved.rect.origin.x = 300
        catchers.update([moved], active: true)
        #expect(catchers.framesInWindow["d"] == moved.rect)

        catchers.update([moved], active: false)
        #expect(catchers.shownCount == 0)
        #expect(!catchers.wantsPointer, "with no page window taking the mouse no area waits")
        #expect(!(window.childWindows ?? []).contains { $0 is DividerMousePanel })
    }

    /// With no pointer moves to feed (no input tap), every area gets its panel at once, as before panels waited.
    @Test func withNoPointerFeedEveryAreaGetsItsPanelAtOnce() {
        let window = Self.window()
        defer { window.close() }
        let catchers = DividerMouseCatchers(window: window, lazy: false, pointerLocation: { .zero })
        defer { catchers.teardown() }

        catchers.update([Self.area], active: true)

        #expect(catchers.shownCount == 1)
        #expect(!catchers.wantsPointer)
        #expect(!catchers.wantsPresses)
    }
}
