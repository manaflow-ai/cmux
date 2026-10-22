import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Dogfood (2026-10-21): a Cmd-clicked link docked its chat left, and the chat's pane showed its header
/// tools on the right of the tab row and no tab at all. A chat that shares the row lies under the strip;
/// shown in Chromium it draws in a window over the pane's, so the strip and toolbar must be left out of
/// it. While a chat shares the row the pane names their frames to it; when it stops, none.
@MainActor @Suite(.serialized) struct TabRowLeavesStripUncoveredTests {
    /// A chat that draws `need` points of tools in the row whenever the pane offers it and records the
    /// holes the pane asks for.
    final class RowChat: NSView, PaneTabRowSharing {
        let need: CGFloat
        private(set) var shared: CGFloat = 0
        private(set) var holes: [CGRect]?
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
            let next = height > 0 ? need : 0
            if height > 0 { offeredOnce = true }
            guard next != shared else { return }
            shared = next
            onTabRowToolsChange?()
        }

        func setTabRowHoles(_ holes: [CGRect]) { self.holes = holes }
    }

    private func pane(width: CGFloat, chat: RowChat) -> (NSWindow, PaneContentView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let items = (0..<2).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        _ = pane.show(chat)
        settle(pane)
        return (window, pane)
    }

    private func settle(_ pane: PaneContentView) {
        // The page answers an offer on a later layout pass; a few passes settle it.
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
    }

    @Test func aChatUnderTheRowLeavesTheStripAndToolbarOut() throws {
        let chat = RowChat(need: 200)
        let (window, pane) = pane(width: 900, chat: chat)
        defer { window.orderOut(nil); window.close() }
        let strip = pane.stripView.frame
        try #require(pane.contentHost.frame.minY < strip.maxY, "the chat does not share the row at 900 pt")
        let holes = try #require(chat.holes, "the pane never told the chat where its strip is")
        let shown = holes.map { pane.convert($0, from: chat) }
        #expect(shown.contains(strip), "the chat covers the tab strip \(strip): holes \(shown)")
        let pill = try #require(pane.stripView.firstTabPillFrame.map { pane.convert($0, from: pane.stripView) })
        #expect(shown.contains { $0.contains(pill) }, "the first tab \(pill) is under the chat: holes \(shown)")
        if let toolbar = pane.toolbar?.view.frame, !toolbar.isEmpty {
            #expect(shown.contains(toolbar), "the chat covers the pane's toolbar \(toolbar): holes \(shown)")
        }
    }

    @Test func aChatThatKeepsItsOwnRowHasNoHoles() throws {
        // Tools wider than half the row keep the chat's own header row, under the strip.
        let chat = RowChat(need: 300)
        let (window, pane) = pane(width: 480, chat: chat)
        defer { window.orderOut(nil); window.close() }
        try #require(pane.contentHost.frame.minY >= pane.stripView.frame.maxY, "the chat still shares the row at 480 pt")
        #expect(chat.holes == [], "a chat under the strip still cuts holes: \(chat.holes ?? [])")
    }
}
