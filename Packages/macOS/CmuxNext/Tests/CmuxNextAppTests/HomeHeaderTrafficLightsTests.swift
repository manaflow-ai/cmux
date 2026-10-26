import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
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

    /// With the list folded the chat column is at the window's top-left: its compose button clears the lights.
    @Test func theChatComposeButtonClearsTheTrafficLights() throws {
        let window = window()
        defer { window.close() }
        let column = HomeChatColumnView(content: NSView(), compose: HomeChatComposeButton(label: "New Message"))
        column.frame = NSRect(x: 0, y: 0, width: 600, height: 640)
        column.showsCompose = true
        window.contentView?.addSubview(column)
        column.layoutSubtreeIfNeeded()
        let lights = try lights(window)
        #expect(!inWindow(column.compose).intersects(lights), "the compose button is under the traffic lights")
    }
}
