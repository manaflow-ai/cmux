import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextTestSupport
@testable import MessagesLabSidebar
import Testing

/// The user, 2026-10-28: "when sidebar closed, imessage UI kinda weird and bad. here's how imessage
/// looks, so we should just match." With the window's sidebar closed the Home list sits under the
/// traffic lights, and its search field ran under them. As in Messages, the lights get the list's
/// top row to themselves with the filter at its right end, and the search field spans the list
/// on the row below. The chat's compose button, under the lights while the list is folded,
/// starts after them.
@MainActor
@Suite(.closesItsWindows)
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
        // New Chief at the row's right end, the toggle just before it.
        #expect(h.newChief.maxX == width - HomeSidebarHeaderLayout.inset)
        #expect(h.filter.maxX + HomeSidebarHeaderLayout.gap == h.newChief.minX)
        #expect(!h.newChief.intersects(lights), "New Chief sits on the traffic lights at \(width)")
        #expect(h.search.width == width - 2 * HomeSidebarHeaderLayout.inset, "the search field does not span the list at \(width)")
        #expect(h.listTop >= h.search.maxY, "the list starts over the search field at \(width)")
        // The views follow the layout.
        #expect(home.searchCapsule.frame == h.search)
        #expect(home.unreadToggle.frame == h.filter)
    }

    /// A list clear of the lights (the window's sidebar open beside it) keeps the lights' row with
    /// nothing on it, so a toggle of the window's sidebar moves Home sideways only (the user,
    /// 2026-11-19, msg 42221: "stuff in the home imessage chief ui shifts around too").
    @Test func theListBesideTheLightsKeepsTheLightsRow() throws {
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
        let lights = try Self.lights(in: home.list.headerView)
        let h = home.header
        #expect(abs(h.filter.midY - lights.midY) <= 1, "the filter left the lights' line beside them")
        #expect(h.newChief.maxX == 320 - HomeSidebarHeaderLayout.inset)
        #expect(h.filter.maxX + HomeSidebarHeaderLayout.gap == h.newChief.minX)
        #expect(h.search.minY >= lights.maxY, "the search field left the row under the lights' line")
        #expect(h.search.width == 320 - 2 * HomeSidebarHeaderLayout.inset)
        #expect(h.listTop > HomeSidebarHeaderLayout.band)
    }

    /// The list moves under the lights (the window's sidebar closes) without a width change: the
    /// header lays out for the lights on the split's next layout.
    @Test func closingTheWindowSidebarMovesTheSearchUnderTheLights() throws {
        let win = Self.window()
        defer { win.close() }
        let suite = "cmux.tests.windowControls.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
        let split = HomeSidebarSplitView(sidebar: home, content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        split.showsList = true // the person showed the list (folded by default: ChiefReplacesHomeTests)
        split.windowKey = { "w" }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        split.frame = NSRect(x: 240, y: 0, width: 760, height: 700)
        root.addSubview(split)
        win.contentView = root
        split.layoutSubtreeIfNeeded()
        home.list.headerView.layoutSubtreeIfNeeded()
        let beside = home.header
        // The sidebar closes: the page slides to the window's edge and grows.
        split.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        split.layoutSubtreeIfNeeded()
        home.list.headerView.layoutSubtreeIfNeeded()
        let lights = try Self.lights(in: home.list.headerView)
        #expect(!home.header.search.intersects(lights))
        #expect(home.header.search.minY >= lights.maxY)
        #expect(home.header == beside, "the window's sidebar closed and Home's header moved")
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
        // Chats (the list's toggle) leads, compose follows it on the same line.
        for button in [column.chats as NSView, compose] {
            #expect(!button.frame.intersects(lights), "\(button) sits on the traffic lights")
            #expect(button.frame.minX >= lights.maxX)
            #expect(abs(button.frame.midY - lights.midY) <= 1, "\(button) is not on the lights' line")
        }
        #expect(compose.frame.minX > column.chats.frame.maxX, "compose overlaps Chats")
        // Beside the list (clear of the lights) Chats keeps its inset.
        column.frame = NSRect(x: 320, y: 0, width: 680, height: 700)
        column.layoutSubtreeIfNeeded()
        #expect(column.chats.frame.minX == HomeChatColumnView.composeInset)
        #expect(compose.frame.minX > column.chats.frame.maxX)
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
        // The search row under the lights and the filter circle on their line.
        #expect(h.search.minY == max(Self.lightsFrame.maxY, h.filter.maxY) + HomeSidebarHeaderLayout.rowGap)
        #expect(h.search.width == width - 2 * HomeSidebarHeaderLayout.inset)
        #expect(h.listTop == h.search.maxY + HomeSidebarHeaderLayout.rowGap)
        #expect(!h.filter.intersects(h.search))
        // New Chief after the toggle on the lights' line, at the row's right end.
        #expect(h.newChief.midY == Self.lightsFrame.midY && h.newChief.size == h.filter.size)
        #expect(h.filter.maxX + HomeSidebarHeaderLayout.gap == h.newChief.minX)
        #expect(h.newChief.maxX == width - HomeSidebarHeaderLayout.inset)
    }

    /// Lights with a wide accessory after them (the incognito badge) leave no room for the toggle
    /// on their row: it stays beside the search field, under them.
    @Test func aWideAccessoryKeepsTheToggleOnTheSearchRow() {
        let controls = CGRect(x: 7, y: 7, width: 170, height: 14)
        let h = HomeSidebarHeaderLayout(width: 200, searchOpen: false, windowControls: controls)
        #expect(!h.filter.intersects(controls) && !h.search.intersects(controls))
        #expect(h.filter.midY == h.search.midY)
        #expect(h.search.maxX + HomeSidebarHeaderLayout.gap == h.filter.minX)
        #expect(h.filter.maxX + HomeSidebarHeaderLayout.gap == h.newChief.minX && h.newChief.maxX <= 200)
    }

    /// The avatar-only list's search and filter circles sit under the lights, the list under them;
    /// an open search sits under them too.
    @Test func theAvatarListUnderTheLights() {
        let closed = HomeSidebarHeaderLayout(width: 90, searchOpen: false, windowControls: Self.lightsFrame)
        #expect(!closed.filter.isEmpty && !closed.searchIcon.isEmpty)
        #expect(!closed.filter.intersects(Self.lightsFrame) && !closed.searchIcon.intersects(Self.lightsFrame))
        #expect(closed.listTop >= closed.filter.maxY)
        let open = HomeSidebarHeaderLayout(width: 90, searchOpen: true, windowControls: Self.lightsFrame)
        #expect(!open.search.intersects(Self.lightsFrame))
        #expect(open.listTop >= open.search.maxY)
    }
}
