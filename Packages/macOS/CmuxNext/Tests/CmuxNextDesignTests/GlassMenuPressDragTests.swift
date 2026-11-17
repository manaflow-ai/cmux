import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Press, drag, release on a glass menu, as on a native one (Lawrence, 2026-11-17: "mousedown mouseup
/// interaction not working here"; Leo: "so he click and hold on the context menu start and then it goes
/// over and then release should go"). The menu opens while the press that opened it is still held, and
/// AppKit sends that press's drags and release to the window it began in, not to the menu's panel: the
/// menu follows the press itself. These tests drive that path with screen points.
@MainActor @Suite(.serialized, .closesItsWindows) struct GlassMenuPressDragTests {
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
            let menu = try #require(inSubmenu ? glass.openChild : glass)
            let view = try #require(menu.list.view(at: index))
            let window = try #require(view.window)
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            return CGPoint(x: rect.midX, y: rect.midY)
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
        glass.followOpeningPress()
        return Fixture(window: window, anchor: anchor, glass: glass, target: target)
    }

    private static func runLoopTurn() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
    }

    /// Fails before the fix: the release went to the sidebar's window and nothing ran.
    @Test func releasingTheOpeningPressOnARowRunsIt() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let settings = try fixture.center(of: 0)
        fixture.glass.pressMoved(to: settings)
        fixture.glass.pressReleased(at: settings)
        #expect(!fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran == ["Settings…"])
    }

    /// Lawrence's gesture: hold on the avatar, drag over Developers (its submenu opens), on to Inspect
    /// Element, release.
    @Test func dragIntoASubmenuAndReleaseRunsTheSubmenuRow() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        fixture.glass.pressMoved(to: try fixture.center(of: 3))
        let inspect = try fixture.center(of: 0, inSubmenu: true)
        fixture.glass.pressMoved(to: inspect)
        fixture.glass.pressReleased(at: inspect)
        #expect(!fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran == ["Inspect Element"])
    }

    /// A click on the control (press and release on it) leaves the menu open, as a native menu does.
    @Test func aClickOnTheControlLeavesTheMenuOpen() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let rect = fixture.window.convertToScreen(fixture.anchor.convert(fixture.anchor.bounds, to: nil))
        fixture.glass.pressReleased(at: CGPoint(x: rect.midX, y: rect.midY))
        #expect(fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran.isEmpty)
    }

    /// A release on a disabled row or on a submenu's row runs nothing and leaves the menu open.
    @Test func releasingOnADisabledOrSubmenuRowLeavesTheMenuOpen() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        let off = try fixture.center(of: 1)
        fixture.glass.pressMoved(to: off)
        fixture.glass.pressReleased(at: off)
        #expect(fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran.isEmpty)
    }

    /// A press dragged over the menu and released outside it closes the menu without running a row.
    @Test func releasingOutsideAfterDraggingOverTheMenuClosesIt() throws {
        let fixture = try Self.fixture()
        defer { fixture.close() }
        fixture.glass.pressMoved(to: try fixture.center(of: 0))
        fixture.glass.pressReleased(at: CGPoint(x: fixture.window.frame.maxX - 10, y: fixture.window.frame.minY + 10))
        #expect(!fixture.glass.isShown)
        Self.runLoopTurn()
        #expect(fixture.target.ran.isEmpty)
    }
}
