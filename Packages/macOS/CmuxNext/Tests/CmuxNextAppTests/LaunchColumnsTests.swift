import AppKit
@testable import CmuxNextHome
import CmuxNextTestSupport
import Testing

/// A bare launch's first frame reserves Home's columns (``LaunchColumnsView``): its message box's
/// column is where Home's split puts the page's at the swap, to the point, so nothing moves.
/// Light and dark, wide (the list at the standard width) and narrow (a lone Chief's list folds).
@MainActor
@Suite(.closesItsWindows)
struct LaunchColumnsTests {
    @Test(arguments: [(CGFloat(1200), NSAppearance.Name.aqua), (1200, .darkAqua), (900, .aqua), (400, .darkAqua)])
    func stage0sChatColumnIsTheSplitsToThePoint(width: CGFloat, look: NSAppearance.Name) throws {
        let page = try HomeLoneChiefRailTests.page(chiefs: 1, width: width)
        defer { page.close() }
        page.window.appearance = NSAppearance(named: look)
        page.split.layoutSubtreeIfNeeded()
        let stage0 = Self.stage0(width: width, look: look)
        defer { stage0.window?.close() }
        let real = try #require(page.split.arrangedSubviews.last).frame
        #expect(stage0.chatFrame == real, "stage 0 \(stage0.chatFrame), the page \(real)")
        #expect(stage0.columns.folded == page.listFolded)
    }

    /// A width the person saved moves the split by the same rule stage 0 uses; a bare launch's new
    /// window has none saved, so stage 0 takes the standard width.
    @Test func aSavedWidthFollowsTheSameRule() throws {
        let page = try HomeLoneChiefRailTests.page(chiefs: 1, width: 1200)
        defer { page.close() }
        HomeSidebarWidth(defaults: page.defaults).save(260, window: "w")
        page.split.needsLayout = true
        page.split.layoutSubtreeIfNeeded()
        let columns = HomeSplitColumns(width: 1200, own: 260, divider: page.split.dividerThickness,
                                       holdsOneConversation: true, loneRail: false)
        #expect(try #require(page.split.arrangedSubviews.last).frame.minX == columns.chatX)
        #expect(LaunchColumnsView.dividerThickness == page.split.dividerThickness)
    }

    static func stage0(width: CGFloat, look: NSAppearance.Name) -> LaunchColumnsView {
        let frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let view = LaunchColumnsView(chat: NSView(), frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return view
    }
}
