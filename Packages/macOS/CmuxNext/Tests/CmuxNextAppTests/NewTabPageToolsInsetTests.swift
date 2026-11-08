import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// #38142: a new workspace's tab is a New Tab page, whose pane shows the page's hover-only "…" (`PaneToolbar.Kind.newTab`).
/// The pane offered the page the row's trailing inset with that "…"'s room in it, and the page draws no tools on the New
/// Tab screen, so the inset sat unused until its first prompt left the screen: the chat's tools (list, terminal, globe,
/// •••) then drew at it, left of an empty "…" slot, and moved right once the chat's session landed and the tab stopped
/// being a New Tab page. The inset a New Tab page is offered is the one its chat's tools keep, and the page's "…" goes
/// in the same layout pass that its tools arrive in.
@MainActor @Suite(.serialized, .closesItsWindows) struct NewTabPageToolsInsetTests {
    /// A New Tab page: it draws no tools in the row until ``leaveNewTab()`` (its first prompt), then `need` points of
    /// a chat's tools, at the inset last offered.
    final class NewTabPage: NSView, PaneTabRowSharing {
        let need: CGFloat
        private(set) var shared: CGFloat = 0
        /// The trailing inset of each row offered, in order.
        private(set) var insets: [CGFloat] = []
        private var chat = false
        private var offered = false
        var onTabRowToolsChange: (() -> Void)?
        init(need: CGFloat) {
            self.need = need
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var tabRowToolsWidth: CGFloat? { shared }
        var tabRowToolsNeed: CGFloat? { shared > 0 ? need : nil }
        func setTabRow(height: CGFloat, trailingInset: CGFloat) {
            guard height > 0 else { return }
            offered = true
            if insets.last != trailingInset { insets.append(trailingInset) }
        }

        /// The page is back on the New Tab screen: no tools in the row.
        func returnToNewTab() {
            chat = false
            guard shared != 0 else { return }
            shared = 0
            onTabRowToolsChange?()
        }

        /// The page leaves the New Tab screen and draws its chat's tools, at the inset it holds, then reports them.
        func leaveNewTab() {
            chat = true
            guard offered, shared != need else { return }
            shared = need
            onTabRowToolsChange?()
        }
    }

    private func newTabPane(in window: NSWindow) -> (PaneContentView, PaneToolbar, NewTabPage) {
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "New Tab")]),
                                   reveal: LaunchReveal(deadline: .zero))
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        // The selected tab is a New Tab page: the pane shows the page's "…".
        toolbar.update(target: "t0", kind: .newTab, paneKinds: [.newTab])
        pane.toolbar = toolbar
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        window.contentView?.addSubview(pane)
        let page = NewTabPage(need: 140)
        _ = pane.show(page)
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
        return (pane, toolbar, page)
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The inset a New Tab page holds is the one its chat's tools keep: no room for the page's "…", which the chat
    /// does not show. The "…" itself stays on the New Tab page, with its own room in the strip.
    @Test func aNewTabPageIsOfferedTheInsetItsChatsToolsKeep() throws {
        let window = window()
        defer { window.orderOut(nil); window.close() }
        let (pane, toolbar, page) = newTabPane(in: window)
        #expect(toolbar.view.hasMore, "the New Tab page keeps its \"…\"")
        #expect(toolbar.view.frame.width > PaneToolbarView.trailingGap, "and the strip gives it its room")
        let inset = try #require(page.insets.last)
        #expect(inset == PaneToolbarView.trailingGap,
                "the chat's tools would draw left of an empty \"…\" slot: inset \(inset), expected \(PaneToolbarView.trailingGap)")
        _ = pane
    }

    /// The page's first prompt: its tools arrive, and the same layout pass drops the page's "…" (the tab store still
    /// calls it a New Tab page until the chat's session lands); the inset the tools drew at does not change.
    @Test func thePagesToolsArriveBesideTheirFinalBar() throws {
        let window = window()
        defer { window.orderOut(nil); window.close() }
        let (pane, toolbar, page) = newTabPane(in: window)
        // What the pane wires (`PaneToolbar.init(pane:)`): the selected page's tools in the row make its tab a chat.
        toolbar.view.pageToolsShown = { [weak page] in (page?.shared ?? 0) > 0 }
        toolbar.view.onPageToolsShown = { [weak toolbar, weak page] in
            toolbar?.update(target: "t0", kind: (page?.shared ?? 0) > 0 ? nil : .newTab, paneKinds: [.newTab])
        }
        let before = try #require(page.insets.last)
        page.leaveNewTab()
        pane.layoutSubtreeIfNeeded() // the one pass the tools' report asks for
        #expect(!toolbar.view.hasMore, "the page's \"…\" left with the New Tab screen")
        #expect(toolbar.view.frame.width == PaneToolbarView.trailingGap, "the bar beside the tools is its trailing gap")
        #expect(page.insets == [before], "the tools moved: offered insets \(page.insets)")
        #expect(pane.stripView.frame.maxX + page.need + before == pane.bounds.width, "the strip ends where the tools begin")
        // Back on the New Tab screen before the session lands (a refused first prompt, a reload): its "…" comes back.
        page.returnToNewTab()
        pane.layoutSubtreeIfNeeded()
        #expect(toolbar.view.hasMore, "the New Tab page's \"…\" is back")
        #expect(page.insets == [before], "the inset the tools would draw at is still the chat's")
    }
}
