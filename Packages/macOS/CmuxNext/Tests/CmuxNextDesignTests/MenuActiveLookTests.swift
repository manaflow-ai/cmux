import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Leo, 2026-11-14: "is this supposed to happen? [the menu] goes from themed to unthemed etc?" The
/// account menu's glass dropped to the grey frost when its submenu took the keys: a menu's panel
/// had plain Liquid Glass, which follows its window's key state. Every menu, submenu and popover
/// panel (`Glass.makeMenuPanel`, a child window of an app window) keeps the app window's key look.
@MainActor @Suite(.closesItsWindows) struct MenuActiveLookTests {
    /// An app window with the backdrop glass and the app's scope, as `NSWindow.install` gives it.
    private func appWindow(_ scope: ActiveLookScope) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = WindowSurfaceView(content: NSView(), activeLook: scope)
        return window
    }

    /// A menu panel as `GlassMenu` builds one, over `parent`: the shared menu surface in the popup style.
    private func menuPanel(over parent: NSWindow) -> NSPanel {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 120), styleMask: [.nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let surface = Glass.makeMenuPanel(content: NSView())
        surface.materialOverride = .liquidGlass
        surface.frame = panel.contentLayoutRect
        panel.adoptPopupStyle(card: surface)
        parent.addChildWindow(panel, ordered: .above)
        // The panel lays its glass out as it comes on screen.
        for glass in glassViews(in: panel.contentView) { glass.needsLayout = true }
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }

    private func glassViews(in view: NSView?) -> [NSView] {
        guard #available(macOS 26.0, *), let view else { return [] }
        return (view is NSGlassEffectView ? [view] : []) + view.subviews.flatMap { glassViews(in: $0) }
    }

    /// The parent menu keeps the key look with its submenu open (the submenu key, the parent not)
    /// exactly as it has it alone, and the submenu has the same.
    @Test func aMenuKeepsItsLookWithItsSubmenuOpen() {
        guard #available(macOS 26.0, *), Glass.isLiquidGlassAvailable else { return }
        let scope = ActiveLookScope()
        let window = appWindow(scope)
        defer { window.closeAfterTest() }
        let parent = menuPanel(over: window)
        defer { parent.closeAfterTest() }
        #expect(!glassViews(in: parent.contentView).isEmpty, "the menu draws Liquid Glass")
        let alone = scope.keepsActiveLook(parent)
        let submenu = menuPanel(over: parent)
        defer { submenu.closeAfterTest() }
        #expect(alone, "the menu alone keeps the app window's key look")
        #expect(scope.keepsActiveLook(parent) == alone, "the parent menu keeps its look with the submenu open")
        #expect(scope.keepsActiveLook(submenu) == alone, "the submenu has the parent's look")
    }

    /// A panel no app window owns follows the key state, as before.
    @Test func aPanelNoAppWindowOwnsFollowsTheKeyState() {
        guard #available(macOS 26.0, *), Glass.isLiquidGlassAvailable else { return }
        let scope = ActiveLookScope()
        let owner = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        owner.isReleasedWhenClosed = false
        owner.contentView = NSView()
        defer { owner.closeAfterTest() }
        let panel = menuPanel(over: owner)
        defer { panel.closeAfterTest() }
        #expect(!scope.keepsActiveLook(panel))
    }
}
