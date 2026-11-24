import AppKit
@testable import CmuxNextHome
@testable import MessagesLabSidebar
import CmuxNextTestSupport
import Testing

/// A narrow Chief column is iPhone Messages (Leo, 2026-11-24): the list or the chat fills it, the Chats
/// button goes back to the list, opening a conversation pushes the chat, and widening is the Mac layout again.
@MainActor
@Suite(.closesItsWindows)
struct HomeSidebarCompactTests {
    private static func split(width: CGFloat, defaults: UserDefaults) -> (HomeSidebarSplitView, NSWindow) {
        _ = NSApplication.shared
        let home = HomeSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        home.update(HomeLoneChiefRailTests.model(chiefs: 3))
        let split = HomeSidebarSplitView(sidebar: home, content: NSView(), widths: HomeSidebarWidth(defaults: defaults))
        split.windowKey = { "compact" }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        return (split, window)
    }

    @Test
    func narrowColumnShowsListOrChatAtFullWidth() throws {
        let suite = "cmux.tests.compact.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (split, window) = Self.split(width: 380, defaults: defaults)
        defer { window.close() }
        #expect(split.isCompact)
        #expect(split.compactShowsChat)
        #expect(split.sidebarWidth == 0)
        #expect(abs(split.transcriptWidth - 380) < 1)
        // Back: the full-width list.
        split.compactShowsChat = false
        #expect(abs(split.sidebarWidth - 380) < 1)
        // A conversation opened: the chat again.
        split.conversationOpened()
        #expect(split.compactShowsChat)
        #expect(split.sidebarWidth == 0)
        // Wider: the Mac layout, the list as the person left it (folded by default).
        window.setContentSize(NSSize(width: 1000, height: 300))
        split.layoutSubtreeIfNeeded()
        #expect(!split.isCompact)
        #expect(abs(split.transcriptWidth - 1000) < 1)
    }
}
