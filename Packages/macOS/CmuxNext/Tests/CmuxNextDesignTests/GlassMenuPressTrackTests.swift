import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Press, hold, drag over a row, release: the row runs, as on a native menu (Lawrence, 2026-11-17:
/// "mousedown mouseup interaction not working here"; Leo: "so he click and hold on the context menu
/// start and then it goes over and then release should go"). The control that opened the menu keeps
/// the mouse, so it hands the press's drags and release to ``GlassMenu/trackPress(_:)``: these tests
/// send it the same `leftMouseDragged` and `leftMouseUp` events, in the control's window, at the
/// rows' places on screen.
@MainActor @Suite(.serialized, .closesItsWindows) struct GlassMenuPressTrackTests {
    private struct Fixture {
        let window: NSWindow
        let anchor: NSView
        let glass: GlassMenu
        let target: GlassMenuActionTarget

        func close() {
            glass.close()
            window.closeAfterTest()
        }

        /// The screen centre of row `index` of the root menu, or of its open submenu.
        func center(of index: Int, inSubmenu: Bool = false) throws -> CGPoint {
            let menu = try #require(inSubmenu ? glass.child : glass)
            let view = try #require(menu.list.view(at: index))
            let window = try #require(view.window)
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        var anchorCenter: CGPoint {
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            return CGPoint(x: rect.midX, y: rect.midY)
        }

        /// A drag (`.leftMouseDragged`) or the release (`.leftMouseUp`) of the press at `point`
        /// (screen), in the control's window, as AppKit delivers it to the control.
        func press(_ type: NSEvent.EventType, at point: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1))
            glass.trackPress(event)
        }
    }

    /// The account menu's shape: Settings, a disabled row, a separator, and Developers with Inspect Element.
    private static func fixture() throws -> Fixture {
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 500, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 32, height: 32))
        window.contentView?.addSubview(anchor)
        let target = GlassMenuActionTarget()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(GlassMenuActionTarget.run(_:)), keyEquivalent: "")
        settings.target = target
        let off = menu.addItem(withTitle: "Off", action: #selector(GlassMenuActionTarget.run(_:)), keyEquivalent: "")
        off.target = target
        off.isEnabled = false
        menu.addItem(.separator())
        let developers = menu.addItem(withTitle: "Developers", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let inspect = sub.addItem(withTitle: "Inspect Element", action: #selector(GlassMenuActionTarget.run(_:)), keyEquivalent: "")
        inspect.target = target
        developers.submenu = sub
        let glass = GlassMenu(menu: menu)
        try #require(glass.show(from: anchor, preferred: .above))
        return Fixture(window: window, anchor: anchor, glass: glass, target: target)
    }

    private static func runLoopTurn() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
    }

    /// Hold, drag onto Settings, release: Settings runs and the menu closes.
    @Test func dragOntoARowAndReleaseRunsIt() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let settings = try fixture.center(of: 0)
        try fixture.press(.leftMouseDragged, at: settings)
        try fixture.press(.leftMouseUp, at: settings)
        #expect(!fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran == ["Settings…"])
    }

    /// Lawrence's gesture: hold, drag over Developers (its submenu opens), on to Inspect Element, release.
    @Test func dragIntoASubmenuAndReleaseRunsTheSubmenuRow() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        try fixture.press(.leftMouseDragged, at: try fixture.center(of: 3))
        #expect(fixture.glass.child != nil, "dragging over Developers did not open its submenu")
        let inspect = try fixture.center(of: 0, inSubmenu: true)
        try fixture.press(.leftMouseDragged, at: inspect)
        try fixture.press(.leftMouseUp, at: inspect)
        #expect(!fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran == ["Inspect Element"])
    }

    /// Press and release on the control is a click: the menu stays open for a second click.
    @Test func aClickOnTheControlLeavesTheMenuOpen() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        try fixture.press(.leftMouseUp, at: fixture.anchorCenter)
        #expect(fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran.isEmpty)
    }

    /// A release on a disabled row, or on a submenu's row, runs nothing and leaves the menu open.
    @Test func releasingOnADisabledOrSubmenuRowLeavesTheMenuOpen() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        for index in [1, 3] {
            let point = try fixture.center(of: index)
            try fixture.press(.leftMouseDragged, at: point)
            try fixture.press(.leftMouseUp, at: point)
            #expect(fixture.glass.isShown, "a release on row \(index) closed the menu")
        }
        Self.runLoopTurn()
        #expect(fixture.target.ran.isEmpty)
    }

    /// Dragged over the menu, then released off it and off the control: the menu closes, nothing runs.
    @Test func releasingOutsideClosesTheMenuAndRunsNothing() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        try fixture.press(.leftMouseDragged, at: try fixture.center(of: 0))
        try fixture.press(.leftMouseUp, at: CGPoint(x: fixture.window.frame.maxX - 10, y: fixture.window.frame.minY + 10))
        #expect(!fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran.isEmpty)
    }
}
