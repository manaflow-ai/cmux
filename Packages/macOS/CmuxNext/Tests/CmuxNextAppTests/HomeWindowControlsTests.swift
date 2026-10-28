import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import Testing

/// The user, 2026-10-28: "when sidebar closed, imessage UI kinda weird and bad. here's how imessage
/// looks, so we should just match." With the window's sidebar closed the Home list sits under the
/// traffic lights, and its search field ran under them. As in Messages, the lights get the list's
/// top row to themselves with the filter at its right end, and the search field spans the list
/// on the row below. The chat's compose button, under the lights while the list is folded,
/// starts after them.
@MainActor
struct HomeWindowControlsTests {
    /// A titled window with a full-size content view, as the app's: its traffic lights sit over
    /// the top-left of the content.
    private static func window(width: CGFloat = 1000) -> NSWindow {
        _ = NSApplication.shared
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        return win
    }

    private static func lights(in view: NSView) throws -> CGRect {
        let window = try #require(view.window)
        let frame = try #require(WindowTitlebar.trafficLightsFrame(in: window))
        return view.convert(frame, from: nil)
    }

    /// The list at the window's left edge: the lights alone on the top row, the filter at its
    /// right end on their line, then the search field across the list under them.
    @Test(arguments: [200, 260, 320, 480] as [CGFloat])
    func theListUnderTheLightsGivesThemTheTopRow(_ width: CGFloat) throws {
        let win = Self.window()
        defer { win.close() }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        home.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        root.addSubview(home)
        win.contentView = root
        home.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        let header = home.list.headerView
        let lights = try Self.lights(in: header)
        let h = home.header
        #expect(!h.search.intersects(lights), "the search field runs under the traffic lights at \(width)")
        #expect(!h.filter.intersects(lights), "the filter sits on the traffic lights at \(width)")
        #expect(h.search.minY >= lights.maxY, "the search field is not under the lights' row at \(width)")
        #expect(abs(h.filter.midY - lights.midY) <= 1, "the filter is not on the lights' line at \(width)")
        #expect(h.filter.maxX == width - HomeSidebarHeaderLayout.inset)
        #expect(h.search.width == width - 2 * HomeSidebarHeaderLayout.inset, "the search field does not span the list at \(width)")
        #expect(h.listTop >= h.search.maxY, "the list starts over the search field at \(width)")
        // The views follow the layout.
        #expect(home.searchCapsule.frame == h.search)
        #expect(home.unreadToggle.frame == h.filter)
    }

    /// A list clear of the lights (the window's sidebar open beside it) keeps the one row.
    @Test func theListBesideTheLightsKeepsOneRow() throws {
        let win = Self.window()
        defer { win.close() }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        home.frame = NSRect(x: 240, y: 0, width: 320, height: 700)
        root.addSubview(home)
        win.contentView = root
        home.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        #expect(home.header == HomeSidebarHeaderLayout(width: 320, searchOpen: false))
    }

    /// The list moves under the lights (the window's sidebar closes) without a width change: the
    /// header lays out for the lights on the split's next layout.
    @Test func closingTheWindowSidebarMovesTheSearchUnderTheLights() throws {
        let win = Self.window()
        defer { win.close() }
        let suite = "cmux.tests.windowControls.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        let split = HomeSidebarSplitView(sidebar: home, content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "w" }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        split.frame = NSRect(x: 240, y: 0, width: 760, height: 700)
        root.addSubview(split)
        win.contentView = root
        split.layoutSubtreeIfNeeded()
        home.list.headerView.layoutSubtreeIfNeeded()
        #expect(home.header.listTop == HomeSidebarHeaderLayout.band)
        // The sidebar closes: the page slides to the window's edge and grows.
        split.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        split.layoutSubtreeIfNeeded()
        home.list.headerView.layoutSubtreeIfNeeded()
        let lights = try Self.lights(in: home.list.headerView)
        #expect(!home.header.search.intersects(lights))
        #expect(home.header.search.minY >= lights.maxY)
    }

    /// The chat's compose button under the lights (a folded list, or the chat at the window's
    /// edge) starts after them, on their line.
    @Test func theChatComposeStartsAfterTheLights() throws {
        let win = Self.window()
        defer { win.close() }
        let compose = HomeChatComposeButton(label: "New Message")
        let column = HomeChatColumnView(content: NSView(), compose: compose)
        column.showsCompose = true
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        column.frame = root.bounds
        root.addSubview(column)
        win.contentView = root
        column.layoutSubtreeIfNeeded()
        let lights = try Self.lights(in: column)
        #expect(!compose.frame.intersects(lights), "compose sits on the traffic lights")
        #expect(compose.frame.minX >= lights.maxX)
        #expect(abs(compose.frame.midY - lights.midY) <= 1, "compose is not on the lights' line")
        // Beside the list (clear of the lights) it keeps its inset.
        column.frame = NSRect(x: 320, y: 0, width: 680, height: 700)
        column.layoutSubtreeIfNeeded()
        #expect(compose.frame.minX == HomeChatColumnView.composeInset)
    }

    // MARK: The layout alone

    /// Lights as a window draws them (x 7 to 59, centred 14 pt from the top), in header points.
    nonisolated static let lightsFrame = CGRect(x: 7, y: 7, width: 52, height: 14)

    /// Every list width with names: nothing overlaps the lights, the row order is Messages'.
    @Test(arguments: [180, 200, 260, 320, 480] as [CGFloat])
    func theLayoutUnderTheLights(_ width: CGFloat) {
        let h = HomeSidebarHeaderLayout(width: width, searchOpen: false, windowControls: Self.lightsFrame)
        #expect(!h.search.intersects(Self.lightsFrame) && !h.filter.intersects(Self.lightsFrame))
        #expect(h.filter.midY == Self.lightsFrame.midY)
        #expect(h.search.minY == Self.lightsFrame.maxY + HomeSidebarHeaderLayout.rowGap)
        #expect(h.search.width == width - 2 * HomeSidebarHeaderLayout.inset)
        #expect(h.listTop == h.search.maxY + HomeSidebarHeaderLayout.rowGap)
        #expect(!h.filter.intersects(h.search))
    }

    /// Lights with a wide accessory after them (the incognito badge) leave no room for the toggle
    /// on their row: it stays beside the search field, under them.
    @Test func aWideAccessoryKeepsTheToggleOnTheSearchRow() {
        let controls = CGRect(x: 7, y: 7, width: 170, height: 14)
        let h = HomeSidebarHeaderLayout(width: 200, searchOpen: false, windowControls: controls)
        #expect(!h.filter.intersects(controls) && !h.search.intersects(controls))
        #expect(h.filter.midY == h.search.midY)
        #expect(h.search.maxX + HomeSidebarHeaderLayout.gap == h.filter.minX)
    }

    /// The avatar-only list keeps its band under the lights; an open search sits under them.
    @Test func theAvatarListUnderTheLights() {
        let closed = HomeSidebarHeaderLayout(width: 90, searchOpen: false, windowControls: Self.lightsFrame)
        #expect(closed.listTop == HomeSidebarHeaderLayout.band)
        let open = HomeSidebarHeaderLayout(width: 90, searchOpen: true, windowControls: Self.lightsFrame)
        #expect(!open.search.intersects(Self.lightsFrame))
        #expect(open.listTop >= open.search.maxY)
    }
}
