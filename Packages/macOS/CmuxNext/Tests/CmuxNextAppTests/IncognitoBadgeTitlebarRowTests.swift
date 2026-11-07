import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// An incognito window's mark in the sidebar's titlebar row (cmux #37351): a sidebar too narrow
/// for the "Incognito" chip showed the glasses glyph alone in a caption-height gray pill stretched
/// to the leftover width, off-size and off the + (New Workspace) button's line. It now is an icon
/// of the row there: a square of the toolbar buttons' side on the +'s frame line, with no fill,
/// and the narrowest sidebar still has room for it.
@MainActor @Suite(.serialized, .closesItsWindows) struct IncognitoBadgeTitlebarRowTests {
    func root() -> (NSWindow, WindowRootView, IncognitoBadgeView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        let badge = IncognitoBadgeView()
        root.sidebar.sidebarView.titlebarAccessory = badge
        settle(root)
        return (window, root, badge)
    }

    func settle(_ root: WindowRootView) {
        for _ in 0..<2 {
            root.needsLayout = true
            root.layoutSubtreeIfNeeded()
        }
    }

    /// A sidebar width that leaves the badge more than a button's side but less than the chip.
    func narrowWidth(_ root: WindowRootView, badge: IncognitoBadgeView) -> CGFloat {
        let sidebarView = root.sidebar.sidebarView
        let button = SidebarStyle.toolbarButtonSize
        let room = button + 2
        #expect(room < badge.fittingSize.width)
        // The + ends `space3` before the trailing edge; the badge keeps `space2` before it.
        return sidebarView.titlebarLeadingX + room + Metrics.space2 + button + Metrics.space3
    }

    @Test func aNarrowSidebarShowsTheMarkAsASquareIconOnThePlusButtonsLine() throws {
        let (window, root, badge) = root()
        defer { window.close() }
        root.sidebar.restore(width: narrowWidth(root, badge: badge), presentation: .shown)
        settle(root)
        let plus = root.sidebar.sidebarView.newButton.frame
        #expect(!badge.isHidden)
        #expect(badge.frame.width == plus.width && badge.frame.height == plus.height)
        #expect(badge.frame.minY == plus.minY)
        #expect(!badge.showsLabel)
        // No gray pill behind the lone glyph.
        let fill = try #require(badge.layer?.backgroundColor)
        #expect(fill.alpha == 0)
        // The glyph centers in the square at the toolbar buttons' glyph size.
        let glyph = try #require(badge.glyph)
        #expect(glyph.size.height == Metrics.smallIconSize)
    }

    @Test func aWideSidebarShowsTheChipCenteredOnThePlusButtonsLine() {
        let (window, root, badge) = root()
        defer { window.close() }
        root.sidebar.restore(width: 320, presentation: .shown)
        settle(root)
        let plus = root.sidebar.sidebarView.newButton.frame
        #expect(!badge.isHidden)
        #expect(badge.showsLabel)
        #expect(badge.frame.size == badge.fittingSize)
        #expect(abs(badge.frame.midY - plus.midY) <= 0.5)
    }

    @Test func theNarrowestSidebarStillShowsTheMark() {
        let (window, root, badge) = root()
        defer { window.close() }
        root.sidebar.restore(width: 1, presentation: .shown)
        settle(root)
        #expect(!badge.isHidden)
        #expect(badge.frame.width >= SidebarStyle.toolbarButtonSize)
    }
}
