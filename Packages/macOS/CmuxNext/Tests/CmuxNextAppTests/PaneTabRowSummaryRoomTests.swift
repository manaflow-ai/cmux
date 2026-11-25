import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// https://github.com/manaflow-ai/cmux/issues/53314: "we need to make it use more of the horizontal space that we have
/// there? but its not for some reason (its many tabs crammed into 1/3 of the space which is weird.. one tab is crammed
/// and need to scroll". A chat's rolling summary (an accessory of the tab row, header/tabRow.ts TAB_ROW_ACCESSORY) took up
/// to half of the pane's row, and was kept there for the chat while another tab was selected: the tabs shrank and
/// scrolled beside it, or beside its empty room. Now the tabs come first: the strip gives up the toolbar and the chat's
/// tools, and the summary only what the tabs leave at their full width.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneTabRowSummaryRoomTests {
    /// A chat whose tools `need` points, and `summary` more while its summary shows (the page's own fit, at most the
    /// room the pane offers, hidden under 160pt).
    final class SummaryChat: NSView, PaneTabRowSharing, PaneParkableContent {
        let row = AgentPaneTabRow()
        let need: CGFloat, summary: CGFloat
        private(set) var offeredRoom: CGFloat = .infinity

        init(need: CGFloat, summary: CGFloat) {
            (self.need, self.summary) = (need, summary)
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var tabRowToolsWidth: CGFloat? { row.sharedWidth(zoom: 1) }
        var tabRowToolsNeed: CGFloat? { row.sharedNeed(zoom: 1) }
        var onTabRowToolsChange: (() -> Void)? {
            get { row.onChange }
            set { row.onChange = newValue }
        }

        func setTabRowAccessoryRoom(_ points: CGFloat) { offeredRoom = points }

        func setTabRow(height: CGFloat, trailingInset: CGFloat) {
            guard height > 0 else { return row.report(width: 0) }
            let shown = min(summary, offeredRoom) >= AgentPaneTabRow.accessoryRoomMin ? min(summary, offeredRoom) : 0
            row.report(width: need + shown, need: need)
        }
    }

    final class Terminal: NSView, PaneParkableContent {}

    struct Pane {
        let view: PaneContentView
        let toolbar: PaneToolbar
        let chat: SummaryChat
        let window: NSWindow
    }

    private func settle(_ pane: PaneContentView) {
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
    }

    private func pane(width: CGFloat, tabs count: Int) -> Pane {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let items = [TabItem(id: TabID("chat"), title: "local-gh-review")]
            + (1..<count).map { TabItem(id: TabID("t\($0)"), title: "Add to #4601 the stall history \($0)") }
        let view = PaneContentView(stripModel: TabStripModel(tabs: items, selectedID: TabID("chat")), reveal: LaunchReveal(deadline: .zero))
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry })
        view.toolbar = toolbar
        toolbar.update(target: "chat", kind: nil, paneKinds: [.terminal, .newTab])
        view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        window.contentView?.addSubview(view)
        let chat = SummaryChat(need: 120, summary: 300)
        view.show(chat)
        settle(view)
        return Pane(view: view, toolbar: toolbar, chat: chat, window: window)
    }

    private func flexibleWidths(_ strip: TabStripView) -> [CGFloat] { strip.result.slots.filter(\.isFlexible).map(\.width) }

    /// Two tabs in a wide pane: they keep their full width and the summary shows in the room they leave.
    @Test func aWideRowShowsTheSummaryBesideFullWidthTabs() throws {
        let pane = pane(width: 1512, tabs: 2)
        defer { pane.window.orderOut(nil); pane.window.close() }
        let strip = pane.view.stripView, metrics = strip.metrics
        #expect(flexibleWidths(strip).allSatisfy { $0 == metrics.maxTabWidth }, "\(flexibleWidths(strip))")
        #expect(strip.frame.width >= strip.naturalWidth - 0.5, "strip \(strip.frame.width) < natural \(strip.naturalWidth)")
        #expect(pane.chat.offeredRoom >= AgentPaneTabRow.accessoryRoomMin, "room \(pane.chat.offeredRoom)")
        #expect(try #require(pane.chat.tabRowToolsWidth) > pane.chat.need, "the summary should show in a roomy row")
    }

    /// Enough tabs to fill the row: the tabs run up to the chat's tools (no summary room), shrink only as much as the
    /// whole row needs, and the summary hides. Before, the strip ended half a row early and the tabs scrolled.
    @Test(arguments: [900, 1200, 1512])
    func aFullRowGivesTheSummaryNothing(width: Int) {
        let pane = pane(width: CGFloat(width), tabs: 8)
        defer { pane.window.orderOut(nil); pane.window.close() }
        let strip = pane.view.stripView
        #expect(pane.chat.offeredRoom < AgentPaneTabRow.accessoryRoomMin, "room \(pane.chat.offeredRoom) at \(width)")
        #expect(pane.chat.tabRowToolsWidth == pane.chat.need, "the summary kept its room at \(width)")
        let toolbar = pane.toolbar.view.frame
        #expect(abs(strip.frame.maxX - (toolbar.minX - pane.chat.need)) <= 0.5,
                "the strip ends at \(strip.frame.maxX), the chat's tools start at \(toolbar.minX - pane.chat.need) (\(width)pt)")
    }

    /// The chat with a summary selected once, then a terminal: the strip gives up no room for the chat's summary.
    @Test func aSummaryIsNotKeptForAChatNotSelected() {
        let pane = pane(width: 1200, tabs: 8)
        defer { pane.window.orderOut(nil); pane.window.close() }
        let strip = pane.view.stripView
        let withChat = strip.frame.maxX, bar = pane.toolbar.view.frame.width
        strip.model.selectedID = TabID("t1")
        pane.toolbar.update(target: "t1", kind: .terminal, paneKinds: [.terminal, .newTab])
        pane.view.show(Terminal())
        settle(pane.view)
        #expect(strip.frame.maxX >= withChat - 0.5, "the strip lost room selecting a terminal: \(strip.frame.maxX) < \(withChat)")
        // The chat's slot kept for it is its toolbar and its tools' need, never its summary's room.
        let kept = max(bar + pane.chat.need, pane.toolbar.view.frame.width)
        #expect(strip.frame.maxX >= pane.view.bounds.width - kept - 0.5, "the strip ends at \(strip.frame.maxX), kept \(kept) of \(pane.view.bounds.width)")
    }
}
