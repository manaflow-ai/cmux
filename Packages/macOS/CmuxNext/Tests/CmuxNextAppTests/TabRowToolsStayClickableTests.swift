import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxTheme
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
        let tabRowTakesLoneTab: Bool
        private(set) var shared: CGFloat = 0
        private(set) var tabsShown = true
        var onTabRowToolsChange: (() -> Void)?
        init(need: CGFloat, takesLoneTab: Bool = false) {
            self.need = need
            tabRowTakesLoneTab = takesLoneTab
            super.init(frame: .zero)
        }

        func setTabRowTabs(shown: Bool) { tabsShown = shown }

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

    /// Leo (2026-11-03), on the tab row over a chat alone in its pane: "have even more of that area be not
    /// some row blocking it? cuz isn't it kinda arbitrary anyway if you literally only have one tab there?"
    /// A chat that shares the row hides its pane's one tab (the page shows through); a second tab brings
    /// the strip back. A view that does not take the lone tab (Home's tools) keeps it.
    @Test(arguments: [true, false])
    func aLoneChatTabGivesTheChatTheRow(takesLoneTab: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "Chat")])
        let pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let chat = RowChat(need: 220, takesLoneTab: takesLoneTab)
        _ = pane.show(chat)
        let settle = {
            for _ in 0..<4 {
                pane.needsLayout = true
                pane.layoutSubtreeIfNeeded()
            }
        }
        settle()
        #expect(pane.contentHost.frame.minY < pane.stripView.frame.maxY, "the chat shares the row")
        #expect(pane.stripView.isHidden == takesLoneTab)
        #expect(chat.tabsShown == !takesLoneTab)

        model.tabs.append(TabItem(id: TabID("t1"), title: "Terminal"))
        settle()
        #expect(!pane.stripView.isHidden, "a second tab shows the strip again")
        #expect(chat.tabsShown)
    }

    /// Leo (2026-11-03), on the chat's own color (`appearance.surfaces.agentPane`) drawn as a rectangle
    /// behind the header buttons in the pane's tab row: "it's so obvious to just remove the thing". The
    /// row has no backing: while the chat shares it, the strip behind the tabs stays clear (only the
    /// user's own tab bar color fills it), as the page leaves the row clear behind the tools
    /// (webviews header.css, `html:has(.acpmux-shell[data-tab-row])`). #32039 painted the chat's color here.
    @Test(arguments: [480, 900])
    func theTabRowHasNoBackingWhileTheChatSharesIt(width: Int) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let items = (0..<3).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: items), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let chatColor = ThemeRGB(hex: 0x282938)
        pane.paneScope.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.agentPane: SurfaceBackground(color: chatColor, opacity: 1)]))
        let chat = RowChat(need: 220)
        _ = pane.show(chat)
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
        #expect(pane.stripView.layer?.backgroundColor == nil, "the tab row paints the chat's color behind the tabs")
        // The user's own tab bar color still fills the strip.
        let barColor = ThemeRGB(hex: 0x113355)
        pane.paneScope.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.agentPane: SurfaceBackground(color: chatColor, opacity: 1),
                                                                            .tabBar: SurfaceBackground(color: barColor, opacity: 1)]))
        pane.themeDidChange()
        let fill = try #require(pane.stripView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(abs(fill.blueComponent - barColor.blue) < 0.01, "the strip paints \(fill), not the tab bar's \(barColor)")
    }
}
