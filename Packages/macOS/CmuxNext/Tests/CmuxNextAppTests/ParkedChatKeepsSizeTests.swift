import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Leo (2026-10-21): "THIS WHOLE THING CAUSES A LAYOUT SHIFT WHEN I SIMPLY SWITCH TO IT FROM ANOTHER
/// TAB." A chat shares the pane's tab row, so it fills the whole pane; a terminal or browser sits under
/// the strip. The parked chat followed the content host, so every switch away shrank its page by the
/// strip's height and the switch back grew it again: the page laid out at a size it never shows at,
/// and the transcript moved as the chat came back. A parked chat keeps the frame it shows at.
@MainActor @Suite(.serialized) struct ParkedChatKeepsSizeTests {
    /// A chat that draws its tools in the row whenever the pane offers it, as the page does, and
    /// records every size its page is given.
    final class RowChat: NSView, PaneTabRowSharing, PaneParkableContent {
        private(set) var shared: CGFloat = 0
        private var offeredOnce = false
        var sizes: [CGSize] = []
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

        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
    }

    /// A terminal or browser: parked in place, shown under the strip.
    final class Other: NSView, PaneParkableContent {}

    private func settle(_ pane: PaneContentView) {
        // The page answers an offer on a later layout pass; a few passes settle it.
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
    }

    @Test func aChatShownAgainFromATerminalNeverChangesSize() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let items = (0..<2).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let chat = RowChat()
        _ = pane.show(chat)
        settle(pane)
        let full = chat.frame.size
        let onScreen = chat.convert(chat.bounds, to: nil)
        // The chat shares the row: it fills the pane, the strip over its top.
        #expect(full == pane.bounds.size)

        chat.sizes = []
        let other = Other()
        _ = pane.show(other)
        settle(pane)
        #expect(chat.isHidden)
        #expect(other.frame.height < pane.bounds.height, "a terminal sits under the strip")
        #expect(chat.sizes.isEmpty, "the parked chat was resized to \(chat.sizes)")

        _ = pane.show(chat)
        settle(pane)
        #expect(!chat.isHidden)
        #expect(chat.sizes.isEmpty, "the chat shown again was resized to \(chat.sizes)")
        #expect(chat.frame.size == full)
        #expect(chat.convert(chat.bounds, to: nil) == onScreen)
    }

    @Test func aParkedChatStillFollowsTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let items = (0..<2).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let chat = RowChat()
        _ = pane.show(chat)
        settle(pane)
        _ = pane.show(Other())
        settle(pane)
        pane.setFrameSize(NSSize(width: 1000, height: 600))
        settle(pane)
        // Parked, it is sized as it will show, so showing it needs no redraw at a new size.
        #expect(chat.frame.size == pane.bounds.size)
        chat.sizes = []
        _ = pane.show(chat)
        settle(pane)
        #expect(chat.sizes.isEmpty, "the chat shown again was resized to \(chat.sizes)")
        #expect(chat.frame.size == pane.bounds.size)
    }
}
