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
            // What Leo sees: the strip and its + in the pane, and a tab for each tab.
            #expect(!strip.isHiddenOrHasHiddenAncestor, "\(count) tab(s): the strip hid")
            #expect(strip.frame.height > 0 && pane.bounds.contains(strip.frame), "\(count) tab(s): the strip is out of the pane: \(strip.frame)")
            #expect(pane.contentHost.frame.minY < strip.frame.maxY, "\(count) tab(s): the chat shares the row")
            let plus = strip.newTabButton
            #expect(!plus.isHiddenOrHasHiddenAncestor, "\(count) tab(s): + hid") // hover mode may fade it at rest; it still takes the press
            let plusFrame = strip.contentView.convert(plus.frame, to: strip)
            #expect(plusFrame.width > 0 && strip.bounds.contains(plusFrame), "\(count) tab(s): + is out of the strip: \(plusFrame)")
            #expect(strip.cells.count == count, "\(count) tab(s): the strip draws \(strip.cells.count) tab cell(s)")
            let tabFrames = strip.cells.values.map { strip.tabsClip.convert($0.frame, to: strip) }
            for tab in tabFrames {
                #expect(tab.width > 0 && strip.bounds.contains(CGPoint(x: tab.midX, y: tab.midY)), "\(count) tab(s): a tab is out of the strip: \(tab)")
            }
            frames[count] = strip.frame
            // A tab and + take their own press; the empty space past + moves the window.
            for tab in tabFrames {
                #expect(strip.titlebarHit(at: CGPoint(x: tab.midX, y: tab.midY)) == .strip, "\(count) tab(s): the tab at \(tab) is titlebar")
            }
            #expect(strip.titlebarHit(at: CGPoint(x: plusFrame.midX, y: plusFrame.midY)) == .strip, "\(count) tab(s): + is titlebar")
            let runEnd = strip.mouseRects().map(\.maxX).max() ?? plusFrame.maxX
            #expect(runEnd < strip.bounds.maxX - 2, "\(count) tab(s): no empty space past +")
            #expect(strip.titlebarHit(at: CGPoint(x: (runEnd + strip.bounds.maxX) / 2, y: strip.bounds.midY)) == .empty,
                    "\(count) tab(s): the strip's empty space past + is no titlebar")
        }
        #expect(frames[0] == frames[1] && frames[1] == frames[2], "the strip moved with its tab count: \(frames)")
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
