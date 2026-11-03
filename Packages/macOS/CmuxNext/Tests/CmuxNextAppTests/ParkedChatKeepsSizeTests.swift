import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo (2026-10-21): "THIS WHOLE THING CAUSES A LAYOUT SHIFT WHEN I SIMPLY SWITCH TO IT FROM ANOTHER
/// TAB." A chat shares the pane's tab row, so it fills the whole pane; a terminal or browser sits under
/// the strip. The parked chat followed the content host, so every switch away shrank its page by the
/// strip's height and the switch back grew it again: the page laid out at a size it never shows at,
/// and the transcript moved as the chat came back. A parked chat keeps the frame it shows at.
@MainActor @Suite(.serialized, .closesItsWindows) struct ParkedChatKeepsSizeTests {
    /// The page's tools: drawn in the row whenever the pane offers it, as the chat page does.
    final class RowTools: NSView, PaneTabRowSharing {
        private(set) var shared: CGFloat = 0
        private var offeredOnce = false
        var onTabRowToolsChange: (() -> Void)?
        var tabRowToolsWidth: CGFloat? { shared }
        var tabRowToolsNeed: CGFloat? { shared > 0 || offeredOnce ? 120 : nil }
        func setTabRow(height: CGFloat, trailingInset: CGFloat) {
            let next: CGFloat = height > 0 ? 120 : 0
            if height > 0 { offeredOnce = true }
            guard next != shared else { return }
            shared = next
            onTabRowToolsChange?()
        }
    }

    /// A terminal or browser: parked in place, shown under the strip.
    final class Other: NSView, PaneParkableContent {}

    /// A page that shares the tab row, as the pane hosts it: an `InternalPageView` (the kind of view
    /// `retire` keeps sized with the pane, as it does an `AgentPaneView`) whose content draws tools in
    /// the row. Every size the pane gives it is recorded.
    @MainActor final class Chat {
        let view = InternalPageView(key: "parked-chat-test", page: InternalPageID(rawValue: "chat"), content: RowTools())
        private(set) var sizes: [CGSize] = []
        private var last: CGSize = .zero

        init() {
            last = view.frame.size
            view.postsFrameChangedNotifications = true
            _ = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                       queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteSize() }
            }
        }

        private func noteSize() {
            let size = view.frame.size
            guard size != last else { return }
            last = size
            sizes.append(size)
        }

        func reset() { sizes = [] }
    }

    private func settle(_ pane: PaneContentView) {
        // The page answers an offer on a later layout pass; a few passes settle it.
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
    }

    /// Watches `chat` for 500 ms on the main run loop, a layout pass each frame: its size and its place
    /// in the window never change.
    private func watch(_ chat: Chat, in pane: PaneContentView, stays rect: NSRect) async throws {
        let clock = ContinuousClock()
        let end = clock.now + .milliseconds(500)
        while clock.now < end {
            try await Task.sleep(for: .milliseconds(16))
            pane.layoutSubtreeIfNeeded()
            #expect(chat.view.convert(chat.view.bounds, to: nil) == rect)
        }
        #expect(chat.sizes.isEmpty, "over 500 ms after the switch the chat was resized to \(chat.sizes)")
    }

    private func makePane(_ window: NSWindow) -> PaneContentView {
        let items = (0..<2).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        return pane
    }

    @Test func aChatShownAgainFromATerminalNeverChangesSize() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let pane = makePane(window)
        let chat = Chat()
        _ = pane.show(chat.view)
        settle(pane)
        let full = chat.view.frame.size
        let onScreen = chat.view.convert(chat.view.bounds, to: nil)
        // The chat shares the row: it fills the pane, the strip over its top.
        #expect(full == pane.bounds.size)

        chat.reset()
        let other = Other()
        _ = pane.show(other)
        settle(pane)
        #expect(chat.view.isHidden)
        #expect(other.frame.height < pane.bounds.height, "a terminal sits under the strip")
        #expect(chat.sizes.isEmpty, "the parked chat was resized to \(chat.sizes)")

        _ = pane.show(chat.view)
        settle(pane)
        #expect(!chat.view.isHidden)
        #expect(chat.sizes.isEmpty, "the chat shown again was resized to \(chat.sizes)")
        #expect(chat.view.frame.size == full)
        try await watch(chat, in: pane, stays: onScreen)
    }

    @Test func aParkedChatStillFollowsTheWindow() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let pane = makePane(window)
        let chat = Chat()
        _ = pane.show(chat.view)
        settle(pane)
        _ = pane.show(Other())
        settle(pane)
        pane.setFrameSize(NSSize(width: 1000, height: 600))
        settle(pane)
        // Parked, it is sized as it will show, so showing it needs no redraw at a new size.
        #expect(chat.view.frame.size == pane.bounds.size)
        chat.reset()
        _ = pane.show(chat.view)
        settle(pane)
        #expect(chat.sizes.isEmpty, "the chat shown again was resized to \(chat.sizes)")
        #expect(chat.view.frame.size == pane.bounds.size)
        try await watch(chat, in: pane, stays: chat.view.convert(chat.view.bounds, to: nil))
    }
}
