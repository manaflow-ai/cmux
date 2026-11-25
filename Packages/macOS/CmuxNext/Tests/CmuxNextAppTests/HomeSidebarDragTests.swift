import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import CmuxNextTestSupport
import Testing

/// The Home list's divider drag (the user, 2026-11-24: "try your best to make the sidebar resizable correctly ... it's okay
/// to remove the sidebar at a certain point", then "do what apple does and shift to the smaller/narrower size"): the strip,
/// or the full list at any width up to the widest, from the pointer alone; a drag half way into the strip closes the list.
@MainActor
@Suite(.closesItsWindows)
struct HomeSidebarDragTests {
    private struct Page {
        let split: HomeSidebarSplitView
        let home: HomeSidebarView
        let window: NSWindow
        let defaults: UserDefaults
        let suite: String
        func close() {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func page(width: CGFloat = 1400) throws -> Page {
        _ = NSApplication.shared
        let suite = "cmux.tests.sidebarDrag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        let split = HomeSidebarSplitView(sidebar: home, content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        split.showsList = true
        split.windowKey = { "w" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        return Page(split: split, home: home, window: window, defaults: defaults, suite: suite)
    }

    /// The narrowest full list is MessagesLab's compact width plus the panel's inset.
    @Test func theFullMinimumIsTheListsCompactWidth() {
        #expect(HomeSidebarWidth.fullMinimum == CmuxSidebarView.compactBelow + HomeSidebarView.panelInset)
    }

    @Test func theDragFollowsThePointerAndClosesHalfWayIntoTheStrip() {
        let min = HomeSidebarWidth.minimum, full = HomeSidebarWidth.fullMinimum, mid = (min + full) / 2
        #expect(HomeSidebarWidth.drag(250, widest: 700) == 250)
        #expect(HomeSidebarWidth.drag(full, widest: 700) == full)
        // Between the strip and the full list: the nearer of the two, from the pointer alone.
        #expect(HomeSidebarWidth.drag(full - 1, widest: 700) == full)
        #expect(HomeSidebarWidth.drag(mid, widest: 700) == full)
        #expect(HomeSidebarWidth.drag(mid - 1, widest: 700) == min)
        #expect(HomeSidebarWidth.drag(min + 1, widest: 700) == min)
        #expect(HomeSidebarWidth.drag(min - 10, widest: 700) == min)
        #expect(HomeSidebarWidth.drag(min / 2, widest: 700) == min)
        #expect(HomeSidebarWidth.drag(min / 2 - 1, widest: 700) == 0)
        #expect(HomeSidebarWidth.drag(-40, widest: 700) == 0)
        #expect(HomeSidebarWidth.drag(900, widest: 700) == 700)
        // A window with no room for the full list keeps the strip.
        #expect(HomeSidebarWidth.drag(160, widest: 150) == min)
    }

    /// A width saved or clamped under the full list is the strip.
    @Test(arguments: [100, 120, 144, 160, 187] as [CGFloat])
    func aWidthUnderTheFullListIsTheStrip(_ width: CGFloat) {
        #expect(HomeSidebarWidth.clamp(width, window: 1400) == HomeSidebarWidth.minimum)
        #expect(HomeSidebarWidth.clamp(400, window: 400) == HomeSidebarWidth.minimum) // 400 leaves the list 120 pt
    }

    /// The same rule on the split: the full list at any width, the strip or the full list's minimum under it, and the
    /// widest caps the drag.
    @Test func theDividerTakesEveryWidth() throws {
        let p = try page()
        defer { p.close() }
        let s = p.split
        let widest = HomeSidebarWidth.clamp(.greatestFiniteMagnitude, window: 1400 - s.dividerThickness)
        for w in [188, 200, 259, 260, 300, 326, 420] as [CGFloat] {
            #expect(s.splitView(s, constrainSplitPosition: w, ofSubviewAt: 0) == w)
        }
        #expect(s.splitView(s, constrainSplitPosition: 130, ofSubviewAt: 0) == HomeSidebarWidth.minimum)
        #expect(s.splitView(s, constrainSplitPosition: 170, ofSubviewAt: 0) == HomeSidebarWidth.fullMinimum)
        #expect(s.splitView(s, constrainSplitPosition: 70, ofSubviewAt: 0) == HomeSidebarWidth.minimum)
        #expect(s.splitView(s, constrainSplitPosition: 30, ofSubviewAt: 0) == 0)
        #expect(s.splitView(s, constrainSplitPosition: 1000, ofSubviewAt: 0) == widest)
        #expect(s.splitView(s, constrainMinCoordinate: 0, ofSubviewAt: 0) == 0)
    }

    /// Every width the drag can give lays the list out inside its column: the pinned tiles, their slabs and the rows.
    @Test func everyWidthLaysOutInsideTheColumn() throws {
        let p = try page()
        defer { p.close() }
        for w in stride(from: CGFloat(100), through: 700, by: 9) {
            p.split.setWidth(w)
            p.split.layoutSubtreeIfNeeded()
            p.home.layoutSubtreeIfNeeded()
            let want = w < HomeSidebarWidth.fullMinimum ? HomeSidebarWidth.minimum : w
            #expect(abs(p.split.sidebarWidth - want) < 1, "asked \(w), got \(p.split.sidebarWidth)")
            let m = SidebarMetrics(width: p.home.list.bounds.width)
            let tiles = (0..<5).map(m.tileRect)
            for t in tiles {
                #expect(t.minX >= 0 && t.maxX <= m.width + 0.5, "a tile leaves the \(m.width) pt list")
                let slab = m.tileSelection.offsetBy(dx: t.minX, dy: t.minY)
                #expect(slab.minX >= t.minX && slab.maxX <= t.maxX + 0.5, "a slab leaves its tile at \(m.width) pt")
            }
            #expect(m.textWidth >= 0)
            if m.compact {
                // A wider strip is the narrowest one zoomed: the avatar, row and slab grow with it, the slab stays centred on
                // the avatar, and the unread dot stays beside it.
                let s = m.width / SidebarMetrics.minimumWidth
                #expect(abs(m.compactAvatar - SidebarMetrics.avatar * s) <= 0.5, "a \(m.compactAvatar) pt avatar at \(m.width) pt")
                #expect(abs(m.listRowHeight - SidebarMetrics.rowHeight * s) <= 0.5, "a \(m.listRowHeight) pt row at \(m.width) pt")
                let slab = m.tileSelection.offsetBy(dx: tiles[0].minX, dy: 0)
                #expect(slab.width == min(m.tileWidth, m.compactSelectionWidth), "a \(slab.width) pt slab at \(m.width) pt")
                #expect(slab.width > m.compactAvatar, "the slab is inside its avatar at \(m.width) pt")
                #expect(abs(slab.midX - (m.rowAvatarX + m.compactAvatar / 2)) <= 1, "the slab is off the avatar at \(m.width) pt")
                #expect(m.rowAvatarX - m.compactDotCenterX == 7, "the dot left its avatar at \(m.width) pt")
            }
            let header = p.home.list.headerView.frame
            #expect(header.maxX <= p.home.list.frame.maxX + 0.5, "the header leaves the \(m.width) pt list")
        }
    }

    /// A drag that ends with the list closed hides it as the Chats button does; the button opens it at the width it
    /// had before the drag.
    @Test func aDragThatClosesTheListHidesItAndKeepsItsWidth() throws {
        let p = try page()
        defer { p.close() }
        p.split.setWidth(300)
        p.split.layoutSubtreeIfNeeded()
        p.split.setPosition(0, ofDividerAt: 0) // where `constrainSplitPosition` puts a drag past half the strip
        #expect(p.split.subviews.first?.frame.width ?? 99 < 1, "the list is \(p.split.subviews.first?.frame.width ?? -1) pt")
        p.split.endDrag(from: 300)
        #expect(!p.split.showsList && p.home.isHidden, "the list stayed after the drag closed it")
        #expect(p.split.widths.width(window: "w") == 300)
        p.split.showsList = true
        #expect(abs(p.split.sidebarWidth - 300) < 1, "the Chats button opened the list at \(p.split.sidebarWidth) pt")
    }

    /// A close in a window too narrow for the saved width (it shows less) keeps the saved width, so a wider window grows
    /// the list back; with nothing saved it stays the standard width.
    @Test func aCloseInANarrowWindowKeepsTheSavedWidth() throws {
        let p = try page(width: 700)
        defer { p.close() }
        p.split.widths.save(400, window: "w")
        p.split.needsLayout = true
        p.split.layoutSubtreeIfNeeded()
        #expect(p.split.sidebarWidth < 399, "700 pt shows \(p.split.sidebarWidth) pt, not less than the saved 400")
        p.split.setPosition(0, ofDividerAt: 0)
        p.split.endDrag(from: 400)
        #expect(!p.split.showsList)
        #expect(p.split.widths.width(window: "w") == 400)
        p.split.showsList = true
        p.split.setPosition(0, ofDividerAt: 0)
        p.split.endDrag(from: nil)
        #expect(p.split.widths.width(window: "w") == nil, "a close with nothing saved kept a width")
    }

    /// A drag that ends anywhere open leaves the list shown.
    @Test func aDragThatEndsOpenKeepsTheList() throws {
        let p = try page()
        defer { p.close() }
        p.split.setWidth(HomeSidebarWidth.minimum)
        p.split.layoutSubtreeIfNeeded()
        p.split.endDrag(from: 300)
        #expect(p.split.showsList && !p.home.isHidden)
        #expect(abs(p.split.sidebarWidth - HomeSidebarWidth.minimum) < 1)
    }
}
