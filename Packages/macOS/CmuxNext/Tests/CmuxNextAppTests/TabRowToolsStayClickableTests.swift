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
        var tabRowTakesLoneTab = false
        private(set) var shared: CGFloat = 0
        private(set) var tabsShown = true
        var onTabRowToolsChange: (() -> Void)?
        var tabRowHoleFill: CGColor?
        init(need: CGFloat) {
            self.need = need
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

    /// Leo (2026-11-03), on a chat alone in its pane, whose tab #33132 hid: "i think you guys are currently hiding
    /// it completely when there's only the one tab... but i think that's just too alien of a look", and "there is
    /// nothinig at the top until you make a tab ... i also can't drag from this top area at all?". The strip shows
    /// at the same height and place with no tab, one tab or several, while a chat shares the row, so nothing moves
    /// when the first or second tab arrives; its empty space past + is the window's titlebar, and a tab or + is not.
    @Test func theStripShowsAtOneHeightWhateverItsTabCount() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let model = TabStripModel(tabs: [])
        let pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let chat = RowChat(need: 220)
        _ = pane.show(chat)
        let settle = {
            for _ in 0..<4 {
                pane.needsLayout = true
                pane.layoutSubtreeIfNeeded()
            }
        }
        var frames: [Int: NSRect] = [:]
        for count in [0, 1, 2] {
            model.tabs = (0..<count).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
            settle()
            pane.stripView.syncFromModel()
            pane.stripView.layoutSubtreeIfNeeded()
            let strip = pane.stripView
            #expect(!strip.isHidden, "\(count) tab(s): the strip hid")
            #expect(strip.frame.height > 0, "\(count) tab(s): the strip has no height")
            #expect(chat.tabsShown, "\(count) tab(s): the chat was told the pane draws no tabs")
            #expect(pane.contentHost.frame.minY < strip.frame.maxY, "\(count) tab(s): the chat shares the row")
            frames[count] = strip.frame
            // The empty space at the strip's trailing end moves the window; a tab and + take their own press.
            #expect(strip.titlebarHit(at: CGPoint(x: strip.bounds.maxX - 2, y: strip.bounds.midY)) == .empty,
                    "\(count) tab(s): the strip's empty space is no titlebar")
            for rect in strip.mouseRects() {
                #expect(strip.titlebarHit(at: CGPoint(x: rect.midX, y: strip.bounds.midY)) == .strip)
            }
        }
        #expect(frames[0] == frames[1] && frames[1] == frames[2], "the strip moved with its tab count: \(frames)")
    }

    /// Leo (2026-11-03), after #34327 brought the strip back at one tab: "maybe you can leave it as an optional
    /// toggle feature for now". With `tabs.hideLoneChatTab` on, a chat alone in its pane hides that tab (the page
    /// shows through the row, #33132); a second tab, or the setting off, brings the strip back. A view that does not
    /// take the lone tab (Home's tools) keeps it either way.
    @Test(arguments: [true, false])
    func theLoneTabHidesOnlyWithTheSettingOn(takesLoneTab: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let saved = DesignSettings.shared.hideLoneChatTab
        defer { DesignSettings.shared.hideLoneChatTab = saved; window.orderOut(nil); window.close() }
        let model = TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "Chat")])
        let pane = PaneContentView(stripModel: model, reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        let chat = RowChat(need: 220)
        chat.tabRowTakesLoneTab = takesLoneTab
        _ = pane.show(chat)
        let settle = {
            for _ in 0..<4 {
                pane.needsLayout = true
                pane.layoutSubtreeIfNeeded()
            }
        }
        DesignSettings.shared.hideLoneChatTab = false
        settle()
        #expect(!pane.stripView.isHidden && chat.tabsShown, "the setting off: the lone tab shows")

        DesignSettings.shared.hideLoneChatTab = true
        settle()
        #expect(pane.contentHost.frame.minY < pane.stripView.frame.maxY, "the chat shares the row")
        #expect(pane.stripView.isHidden == takesLoneTab)
        #expect(chat.tabsShown == !takesLoneTab)

        model.tabs.append(TabItem(id: TabID("t1"), title: "Terminal"))
        settle()
        #expect(!pane.stripView.isHidden && chat.tabsShown, "a second tab shows the strip again")
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

    /// #33261: a Chromium chat alone in its pane paints its surface across the row and leaves the pane's "…" a
    /// hole; the toolbar fills its frame with the chat's fill (`tabRowHoleFill`), so the row is one surface, and
    /// goes clear again when the chat leaves the row or gives no fill.
    @Test func theToolbarPaintsTheChatsHoleFill() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("t0"), title: "Chat")]), reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        pane.toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        let chat = RowChat(need: 220)
        let fill = ThemeRGB(hex: 0x282938).cgColor
        chat.tabRowHoleFill = fill
        _ = pane.show(chat)
        let settle = {
            for _ in 0..<4 {
                pane.needsLayout = true
                pane.layoutSubtreeIfNeeded()
            }
        }
        settle()
        let toolbar = try #require(pane.toolbar?.view)
        let plate = { toolbar.layer?.sublayers?.first { $0.backgroundColor != nil && $0.backgroundColor == fill } }
        #expect(pane.contentHost.frame.minY < pane.stripView.frame.maxY, "the chat shares the row")
        let shown = try #require(plate(), "the toolbar paints the chat's surface")
        // The window's lit top rim runs on over the toolbar (#33346): the fill starts below it.
        let rim = PaneTabRowRim.height, bounds = toolbar.bounds
        let top = toolbar.isFlipped ? shown.frame.minY : bounds.height - shown.frame.maxY
        #expect(abs(top - rim) < 0.01 && abs(shown.frame.height - (bounds.height - rim)) < 0.01 && shown.frame.width == bounds.width,
                "the fill \(shown.frame) in \(bounds) covers the rim")
        #expect(toolbar.layer?.backgroundColor == nil, "the toolbar's own background stays clear")
        chat.tabRowHoleFill = nil
        settle()
        #expect(plate() == nil)
    }
}
