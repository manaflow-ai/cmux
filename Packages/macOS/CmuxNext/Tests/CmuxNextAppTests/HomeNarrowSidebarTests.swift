import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import CmuxNextTestSupport
import Testing

/// The user, 2026-10-20 (refs/imessage-layout/2.png, 3.png): "If the sidebar is too small then we
/// just don't have to show the search bar or the filter bar and the compose bar should be shown in
/// the chat UI top left not in the sidebar." As Messages: the avatar-only list has no header row,
/// and a round compose button sits at the chat's top-left, beside the traffic lights; the list with
/// names keeps its search and Unread toggle, and compose stays in the chat (the user, 2026-10-21).
@MainActor
@Suite(.closesItsWindows)
struct HomeNarrowSidebarTests {
    /// The chat's compose button in `view`'s tree, by its accessibility identifier.
    static func chatCompose(in view: NSView) -> NSButton? {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.accessibilityIdentifier() == "cmux.home.chat.compose" { return b }
            return v.subviews.lazy.compactMap(find).first
        }
        return find(view)
    }

    private struct Page {
        let split: HomeSidebarSplitView
        let home: HomeSidebarView
        let content: NSView
        let window: NSWindow
        let defaults: UserDefaults
        let suite: String
        func close() {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func page(listWidth: CGFloat) throws -> Page {
        _ = NSApplication.shared
        let suite = "cmux.tests.narrowSidebar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let content = NSView()
        let split = HomeSidebarSplitView(sidebar: home, content: content, widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "w" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        split.setWidth(listWidth)
        split.layoutSubtreeIfNeeded()
        home.list.headerView.needsLayout = true
        home.list.headerView.layoutSubtreeIfNeeded()
        return Page(split: split, home: home, content: content, window: window, defaults: defaults, suite: suite)
    }

    /// Leo, 2026-10-19: "the search completley disappeared when you coulve probably still fit it...
    /// and/or just turned it to an icon. the filter button also just disappeared." The avatar-only
    /// list keeps the Unread filter and shows search as a glass circle; compose stays the chat's.
    @Test(arguments: [76, 100, 140, 179] as [CGFloat])
    func theAvatarListShowsTheSearchIconAndFilterButNoCompose(_ width: CGFloat) throws {
        let p = try page(listWidth: width)
        defer { p.close() }
        #expect(abs(p.split.sidebarWidth - width) < 1)
        let home = p.home
        #expect(home.compose.isHidden, "compose shows in the \(width) pt list")
        #expect(!home.unreadToggle.isHidden, "the Unread filter is gone from the \(width) pt list")
        #expect(!home.searchButton.isHidden, "the search icon is gone from the \(width) pt list")
        #expect(home.unreadToggle.frame.maxX <= width && home.searchButton.frame.minX >= 0)
        #expect(!home.unreadToggle.frame.intersects(home.searchButton.frame))
        #expect(home.searchCapsule.isHidden, "the search capsule shows in the \(width) pt list")
        #expect(home.list.searchField.alphaValue == 0 || home.list.searchField.frame.width == 0,
                "the search field shows in the \(width) pt list")
    }

    @Test(arguments: [76, 140] as [CGFloat])
    func theChatShowsComposeAtItsTopLeft(_ width: CGFloat) throws {
        let p = try page(listWidth: width)
        defer { p.close() }
        let button = try #require(Self.chatCompose(in: p.split), "no compose button in the chat")
        #expect(!button.isHidden)
        let frame = button.convert(button.bounds, to: p.content)
        let fromTop = p.content.isFlipped ? frame.minY : p.content.bounds.height - frame.maxY
        #expect(frame.minX >= 4 && frame.minX <= 24, "compose sits \(frame.minX) pt from the chat's left edge")
        #expect(fromTop >= 4 && fromTop <= 20, "compose sits \(fromTop) pt under the chat's top")
        #expect(abs(frame.width - frame.height) < 0.5, "compose is no round button (\(frame.size))")
        // A chat the page shows later (a conversation, New Message) never covers it.
        let chat = NSView(frame: p.content.bounds)
        p.content.addSubview(chat)
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        // The window's frame view takes window coordinates.
        let hit = p.window.contentView?.superview?.hitTest(center)
        #expect(hit === button || hit?.isDescendant(of: button) == true, "the chat covers compose (hit \(String(describing: hit)))")
        // The same action as the list's compose.
        var opened = 0
        p.home.onNewMessage = { opened += 1 }
        button.performClick(nil)
        #expect(opened == 1)
        // The New Message page is on screen: compose would sit over To:, and the person composes already.
        p.split.composing = true
        #expect(button.isHidden)
        p.split.composing = false
        #expect(!button.isHidden)
    }

    @Test(arguments: [180, 320] as [CGFloat])
    func theListWithNamesKeepsItsRowAndComposeStaysInTheChat(_ width: CGFloat) throws {
        let p = try page(listWidth: width)
        defer { p.close() }
        #expect(p.home.compose.isHidden && !p.home.unreadToggle.isHidden)
        #expect(!p.home.searchCapsule.isHidden)
        #expect(Self.chatCompose(in: p.split).map { !$0.isHidden } ?? false)
    }
}
