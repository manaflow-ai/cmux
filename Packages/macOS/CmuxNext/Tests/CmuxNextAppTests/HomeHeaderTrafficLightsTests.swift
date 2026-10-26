import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextTabs
import Testing

/// cmux#25593: the docked Home pane has no tab bar, so with the sidebar hidden (Cmd+B) Home's list
/// sits at the window's top-left and its Search field was under the traffic lights. Hiding the
/// sidebar moves the list with no resize of its own, so nothing laid its header out again.
@MainActor @Suite(.serialized) struct HomeHeaderTrafficLightsTests {
    /// A shell window as the app makes it: titled, full-size content, its traffic lights over the top row.
    private func window() -> ShellWindow {
        _ = NSApplication.shared
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        return window
    }

    private func lights(_ window: NSWindow) throws -> CGRect {
        try #require(WindowTitlebar.trafficLightsFrame(in: window))
    }

    private func inWindow(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

    /// Home's list at the window's top-left: the Search field and the Unread toggle start after the lights.
    @Test func theSearchFieldStartsAfterTheTrafficLights() throws {
        let window = window()
        defer { window.close() }
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 640))
        window.contentView?.addSubview(home)
        home.layoutSubtreeIfNeeded()
        let lights = try lights(window)
        let search = inWindow(home.searchCapsule)
        #expect(!search.intersects(lights), "the Search field \(search) is under the traffic lights \(lights)")
        #expect(search.minX >= lights.maxX)
        #expect(!inWindow(home.unreadToggle).intersects(lights))
        #expect(inWindow(home.unreadToggle).maxX <= 300, "the row overflows the list")
    }

    /// Cmd+B: the sidebar hides and the list moves to the window's left edge at the same size, so
    /// no layout of its own runs; the window's top-row re-check (`relayoutTopRowStrips`) moves the row.
    @Test func hidingTheSidebarMovesTheRowClearOfTheTrafficLights() throws {
        let window = window()
        defer { window.close() }
        let home = HomeSidebarView(frame: NSRect(x: 260, y: 0, width: 300, height: 640))
        window.contentView?.addSubview(home)
        home.layoutSubtreeIfNeeded()
        #expect(window.windowControlsAvoiders.count >= 1, "Home's list did not join the window's top-row views")
        #expect(home.header.leading == HomeSidebarHeaderLayout.inset, "the list right of the sidebar reserved room for the lights")

        home.setFrameOrigin(.zero)
        window.windowControlsAvoiders.update(in: window)
        home.layoutSubtreeIfNeeded()
        let lights = try lights(window)
        #expect(!inWindow(home.searchCapsule).intersects(lights), "after the sidebar hid, the Search field stayed under the traffic lights")

        // Cmd+B again: the list moves back right of the sidebar and the row returns to its inset.
        home.setFrameOrigin(NSPoint(x: 260, y: 0))
        window.windowControlsAvoiders.update(in: window)
        home.layoutSubtreeIfNeeded()
        #expect(home.header.leading == HomeSidebarHeaderLayout.inset)
    }

    /// The app's own trigger: a pane with no tab bar (the docked Home) moves in the window at the
    /// same size, and its window-frame report (`paneFrameInWindowDidChange`, from `PaneHostView`)
    /// re-checks the Home header inside it.
    @Test func aPaneMovingUnderTheLightsRechecksHomesHeader() throws {
        let window = window()
        defer { window.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("home"), title: "Home")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.hidesStrip = true
        pane.frame = NSRect(x: 260, y: 0, width: 600, height: 640)
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 640))
        let container = NSView(frame: pane.bounds)
        container.addSubview(home)
        _ = pane.show(container)
        window.contentView?.addSubview(pane)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(home.header.leading == HomeSidebarHeaderLayout.inset)

        pane.setFrameOrigin(.zero)
        pane.paneFrameInWindowDidChange()
        window.contentView?.layoutSubtreeIfNeeded()
        let lights = try lights(window)
        #expect(!inWindow(home.searchCapsule).intersects(lights), "the pane moved under the lights and Home's Search field stayed there")
    }

    /// A hidden workspace keeps the clearance it had: re-checks skip it while hidden, and it
    /// re-checks itself when it shows again.
    @Test func aHiddenWorkspaceKeepsItsClearance() throws {
        let window = window()
        defer { window.close() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 640))
        workspace.addSubview(home)
        window.contentView?.addSubview(workspace)
        home.layoutSubtreeIfNeeded()
        let cleared = home.header.leading
        #expect(cleared > HomeSidebarHeaderLayout.inset)

        workspace.isHidden = true
        window.windowControlsAvoiders.update(in: window)
        workspace.isHidden = false
        home.layoutSubtreeIfNeeded()
        #expect(home.header.leading == cleared)
        #expect(!inWindow(home.searchCapsule).intersects(try lights(window)))
    }

    /// Past the lights the row still fits the list: the field narrows at the narrowest full list,
    /// and an avatar-only list's open search never opens zero-wide.
    @Test(arguments: [180, 190, 200, 260] as [CGFloat])
    func theRowFitsPastTheLights(_ width: CGFloat) {
        let h = HomeSidebarHeaderLayout(width: width, searchOpen: false, windowControls: 84)
        #expect(h.leading == 84)
        #expect(h.search.minX == 84 && h.search.width >= HomeSidebarHeaderLayout.side)
        #expect(h.filter.maxX <= width - HomeSidebarHeaderLayout.inset, "the row overflows \(width)")
    }

    @Test(arguments: [60, 100, 140] as [CGFloat])
    func anOpenSearchInAnAvatarListIsNeverZeroWide(_ width: CGFloat) {
        let h = HomeSidebarHeaderLayout(width: width, searchOpen: true, windowControls: 84)
        #expect(h.compact)
        #expect(h.search.width >= min(HomeSidebarHeaderLayout.side, width - 2 * HomeSidebarHeaderLayout.inset))
        #expect(h.search.maxX <= width - HomeSidebarHeaderLayout.inset)
    }

    /// With the list folded the chat column is at the window's top-left: its compose button clears the lights.
    @Test func theChatComposeButtonClearsTheTrafficLights() throws {
        let window = window()
        defer { window.close() }
        let column = HomeChatColumnView(content: NSView(), compose: HomeChatComposeButton(label: "New Message"))
        column.frame = NSRect(x: 260, y: 0, width: 600, height: 640)
        column.showsCompose = true
        window.contentView?.addSubview(column)
        column.layoutSubtreeIfNeeded()
        #expect(column.compose.frame.minX == HomeChatColumnView.composeInset)

        column.setFrameOrigin(.zero)
        window.windowControlsAvoiders.update(in: window)
        column.layoutSubtreeIfNeeded()
        let lights = try lights(window)
        #expect(!inWindow(column.compose).intersects(lights), "the compose button is under the traffic lights")
    }

    /// The shared measure (`WindowTitlebar.windowControlsMaxX`): only what lies over the shown part counts.
    @Test func onlyObstaclesOverTheShownPartCount() {
        let lights = CGRect(x: 8, y: 600, width: 52, height: 16)
        let row = CGRect(x: 0, y: 596, width: 300, height: 28)
        #expect(WindowTitlebar.windowControlsMaxX(over: row, shown: .infinite, lights: lights, accessory: nil) == 60)
        // Below the lights, or with the row's part under them clipped away: nothing to clear.
        #expect(WindowTitlebar.windowControlsMaxX(over: row.offsetBy(dx: 0, dy: -60), shown: .infinite, lights: lights, accessory: nil) == nil)
        #expect(WindowTitlebar.windowControlsMaxX(over: row, shown: CGRect(x: 100, y: 0, width: 900, height: 700), lights: lights, accessory: nil) == nil)
        // The open toolbar band after the lights (the accessory) is cleared too.
        let band = CGRect(x: 72, y: 598, width: 90, height: 20)
        #expect(WindowTitlebar.windowControlsMaxX(over: row, shown: .infinite, lights: lights, accessory: band) == 162)
    }
}
