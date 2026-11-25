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
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        let content = NSView()
        let split = HomeSidebarSplitView(sidebar: home, content: content, widths: HomeSidebarWidth(defaults: defaults))
        split.showsList = true // the person showed the list (folded by default: ChiefReplacesHomeTests)
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

    /// The avatar-only list is Messages' strip (the user, 2026-11-24): a width under the full list snaps to it, and it
    /// shows no search, filter or compose (compose is the chat's).
    @Test(arguments: [100, 120, 140, 187] as [CGFloat])
    func theAvatarListIsMessagesStrip(_ width: CGFloat) throws {
        let p = try page(listWidth: width)
        defer { p.close() }
        #expect(abs(p.split.sidebarWidth - HomeSidebarWidth.minimum) < 1, "\(width) pt did not snap to the strip")
        let home = p.home
        #expect(home.compose.isHidden && home.unreadToggle.isHidden && home.searchButton.isHidden, "a button shows in the strip")
        #expect(home.searchCapsule.isHidden, "the search capsule shows in the strip")
        #expect(home.list.searchField.alphaValue == 0 || home.list.searchField.frame.width == 0, "the search field shows in the strip")
    }

    @Test(arguments: [100, 140] as [CGFloat])
    func theChatShowsComposeAtItsTopLeft(_ width: CGFloat) throws {
        let p = try page(listWidth: width)
        defer { p.close() }
        let button = try #require(Self.chatCompose(in: p.split), "no compose button in the chat")
        #expect(!button.isHidden)
        let frame = button.convert(button.bounds, to: p.content)
        let fromTop = p.content.isFlipped ? frame.minY : p.content.bounds.height - frame.maxY
        // Chats sits at the chat's top-left (the Chief replaces Home, 2026-11-20), compose right after it.
        let chats = p.split.chatColumn.chats.convert(p.split.chatColumn.chats.bounds, to: p.content)
        #expect(chats.minX >= 4 && chats.minX <= 24, "Chats sits \(chats.minX) pt from the chat's left edge")
        #expect(frame.minX > chats.maxX && frame.minX <= chats.maxX + 16, "compose sits at \(frame.minX) pt, Chats ends at \(chats.maxX) pt")
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

    @Test(arguments: [188, 320] as [CGFloat])
    func theListWithNamesKeepsItsRowAndComposeStaysInTheChat(_ width: CGFloat) throws {
        let p = try page(listWidth: width)
        defer { p.close() }
        #expect(p.home.compose.isHidden && !p.home.unreadToggle.isHidden)
        #expect(!p.home.searchCapsule.isHidden)
        #expect(Self.chatCompose(in: p.split).map { !$0.isHidden } ?? false)
    }
}
