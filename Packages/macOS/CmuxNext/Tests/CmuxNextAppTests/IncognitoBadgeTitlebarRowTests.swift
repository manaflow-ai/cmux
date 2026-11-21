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
        let badge = IncognitoBadgeView(title: WindowStrings.incognitoBadge, help: WindowStrings.incognitoHelp)
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
        // The width below assumes the + stands alone (the defaults): no Priority bell, no chooser chevron.
        #expect(sidebarView.priorityButton.isHidden)
        let button = SidebarStyle.toolbarButtonSize
        let room = button + 2
        #expect(room < badge.fittingSize.width)
        // The + centers on the trailing column (`titlebarPlusTrailingInset` from the edge); the badge keeps `space2` before it.
        return sidebarView.titlebarLeadingX + room + Metrics.space2 + button + SidebarStyle.titlebarPlusTrailingInset
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
        // The faded chip keeps its own layout: its word is never squeezed into the square.
        #expect(badge.wordFits)
    }

    /// Widening a narrow sidebar brings the chip back laid out as one made wide.
    @Test func wideningANarrowSidebarBringsTheChipBackWhole() {
        let (window, root, badge) = root()
        defer { window.close() }
        root.sidebar.restore(width: narrowWidth(root, badge: badge), presentation: .shown)
        settle(root)
        #expect(!badge.showsLabel)
        root.sidebar.restore(width: 320, presentation: .shown)
        settle(root)
        #expect(badge.showsLabel)
        #expect(badge.frame.size == badge.fittingSize)
        #expect(badge.wordFits)
        #expect(abs(badge.wordGap - Metrics.space1) <= 0.5)
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
        // The whole word draws: its last letter was clipped when the label's frame left out its line padding.
        #expect(badge.wordFits)
        #expect(abs(badge.wordGap - Metrics.space1) <= 0.5)
        #expect(abs(badge.frame.midY - plus.midY) <= 0.5)
    }

    @Test func theNarrowestSidebarStillShowsTheMark() {
        let (window, root, badge) = root()
        defer { window.close() }
        root.sidebar.restore(width: 1, presentation: .shown)
        settle(root)
        let sidebarView = root.sidebar.sidebarView
        let plus = sidebarView.newButton.frame
        #expect(!badge.isHidden)
        // At least the row's square icon, clear of the + (whichever the sidebar's other minimums leave).
        #expect(badge.showsLabel || (badge.frame.width == plus.width && badge.frame.height == plus.height))
        #expect(badge.frame.maxX + Metrics.space2 <= plus.minX)
    }
}
