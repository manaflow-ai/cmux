import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo's nightly (c78e7b2, 2026-10-21): a chat's header tools sat in the pane's tab row, but the
/// leading ones (terminal, browser) took no clicks. The strip gave the chat at most half the row,
/// so in a pane narrower than twice the tools its empty space ran under them; a press there is the
/// strip's, and in the top row empty strip space moves the window (`TabStripView.titlebarPress`).
/// Whatever the pane's width, while the chat lies under the row the strip ends where its tools begin.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabRowToolsStayClickableTests {
    /// A chat that draws `need` points of tools in the row whenever the pane offers it, as the page does.
    final class RowChat: NSView, PaneTabRowSharing {
        let need: CGFloat
        private(set) var shared: CGFloat = 0
        var onTabRowToolsChange: (() -> Void)?
        init(need: CGFloat) {
            self.need = need
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var tabRowToolsWidth: CGFloat? { shared }
        var tabRowToolsNeed: CGFloat? { shared > 0 || offeredOnce ? need : nil }
        private var offeredOnce = false
        func setTabRow(height: CGFloat, trailingInset: CGFloat) {
            let next = height > 0 ? need : 0
            if height > 0 { offeredOnce = true }
            guard next != shared else { return }
            shared = next
            onTabRowToolsChange?()
        }
    }

    @Test(arguments: [360, 480, 640, 900])
    func theStripNeverRunsUnderTheChatsTools(width: Int) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let items = (0..<3).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let chat = RowChat(need: 220)
        _ = pane.show(chat)
        // The page answers an offer on a later layout pass; a few passes settle it.
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
        let strip = pane.stripView.frame
        let chatUnderRow = pane.contentHost.frame.minY < strip.maxY
        if chatUnderRow {
            #expect(strip.maxX + chat.need <= pane.bounds.width - pane.toolbarWidth(shown: strip.height) + 0.5,
                    "at \(width) pt the strip ends at \(strip.maxX), over \(chat.need) pt of tools")
        }
        // A pane wide enough for the tools shares the row; a narrow one keeps the chat's own header row.
        #expect(chatUnderRow == (CGFloat(width) - pane.toolbarWidth(shown: strip.height) >= chat.need * 2))
    }
}
