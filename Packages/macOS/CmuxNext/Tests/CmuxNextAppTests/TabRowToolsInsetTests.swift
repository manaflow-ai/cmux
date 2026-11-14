import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo, 2026-11-07, on two chats side by side: "there's sometimes this, like, ghost area where it thinks there's, like,
/// a fifth icon or something" and "this just gets, like, askew". The pane's toolbar keeps room for a "…" whichever tab
/// is selected (so a selection moves no tab), and that room was the chat's trailing inset in the row: an empty slot
/// after the chat's own "…" in a pane that also holds a terminal, and no inset at all in a pane of chats only. Beside a
/// chat in the row the toolbar is what it shows and the trailing gap, the same in every pane.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabRowToolsInsetTests {
    /// A chat that draws `need` points of tools in the row and keeps the inset it was offered.
    final class RowChat: NSView, PaneTabRowSharing {
        let need: CGFloat
        private(set) var shared: CGFloat = 0
        private(set) var inset: CGFloat?
        private var offeredOnce = false
        var onTabRowToolsChange: (() -> Void)?
        init(need: CGFloat) {
            self.need = need
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var tabRowToolsWidth: CGFloat? { shared }
        var tabRowToolsNeed: CGFloat? { shared > 0 || offeredOnce ? need : nil }
        func setTabRow(height: CGFloat, trailingInset: CGFloat) {
            if height > 0 { offeredOnce = true; inset = trailingInset }
            let next = height > 0 ? need : 0
            guard next != shared else { return }
            shared = next
            onTabRowToolsChange?()
        }
    }

    private func pane(width: CGFloat, paneKinds: Set<PaneToolbar.Kind>, in window: NSWindow) -> (PaneContentView, RowChat) {
        let items = (0..<2).map { TabItem(id: TabID("t\($0)"), title: "Chat \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        // The chat is selected (kind nil: no "…"); `paneKinds` is what the pane's other tabs offer.
        toolbar.update(target: "t0", kind: nil, paneKinds: paneKinds)
        pane.toolbar = toolbar
        pane.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        window.contentView?.addSubview(pane)
        let chat = RowChat(need: 140)
        _ = pane.show(chat)
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
        return (pane, chat)
    }

    @Test(arguments: [480, 900])
    func twoPanesGiveTheirChatsOneTrailingInset(width: Int) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width) * 2, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        // Left: a pane that also holds a terminal (its toolbar keeps "…"'s room). Right: chats only (no room kept).
        let (left, leftChat) = pane(width: CGFloat(width), paneKinds: [.terminal], in: window)
        let (right, rightChat) = pane(width: CGFloat(width), paneKinds: [], in: window)
        #expect(left.toolbar?.view.reservedCount == 1, "the terminal's \"…\" keeps its room for the strip")
        let leftInset = try #require(leftChat.inset), rightInset = try #require(rightChat.inset)
        #expect(leftInset == rightInset, "one right inset in every pane: \(leftInset) vs \(rightInset)")
        // The inset is the toolbar's shown buttons (none beside a chat) and its trailing gap: no slot for a hidden "…".
        #expect(leftInset == PaneToolbarView.trailingGap)
        #expect(leftInset < left.toolbarWidth(shown: left.shownStripHeight), "the hidden \"…\"'s room is not the chat's")
        // The strip ends where the chat's tools begin, in both panes alike.
        #expect(left.stripView.frame.maxX == right.stripView.frame.maxX)
        #expect(left.stripView.frame.maxX + leftChat.need + leftInset == CGFloat(width))
    }

    /// The bar beside a chat is the sum of what it shows: no reserved slot, "…" counted only while it shows.
    @Test func theRowWidthIsItsShownButtons() {
        let view = PaneToolbarView()
        view.show([], more: false, lit: false, reserving: 3)
        #expect(view.tabRowWidth == PaneToolbarView.trailingGap)
        #expect(view.intrinsicContentSize.width > view.tabRowWidth, "the strip keeps the reserved room")
        view.show([], more: true, lit: false, reserving: 3)
        #expect(view.tabRowWidth == PaneToolbarView.trailingGap + TitlebarBandButton.side)
    }
}
