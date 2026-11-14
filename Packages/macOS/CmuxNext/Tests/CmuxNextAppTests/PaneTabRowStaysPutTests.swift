import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Leo, 2026-11-07 (Trace-ID ask-11b77f340e): "when you navigate between different tabs inside of a pane, and it's like a
/// tight space ... Like you open a tab, or you close a tab, or you're selecting between tabs ... There's a bit of a hop,
/// skip, and a jump. ... the top right button area is somehow, like, shifting its layout". His recording: a narrow pane
/// with GitHub, a chat and New Tab; closing New Tab showed the chat's tools in a second row under the tabs, then they
/// jumped up into the tab row under the still pointer.
///
/// Two causes, both covered here at narrow and wide pane widths:
/// - the strip's width followed the selected tab's trailing room (a chat's tools beside its toolbar, a terminal's "…"), so
///   a selection, an open or a close moved the tabs' end and the toolbar's slot;
/// - a chat whose page loads again (a discarded chat shown) has no width until it reports, and the pane laid the chat
///   under the strip until then: its tools in a second row, then up into the row.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneTabRowStaysPutTests {
    /// A chat as the pane sees it: its tab row model (``AgentPaneTabRow``) and a page that answers each new offer as the
    /// page does, one report per `deliver()`.
    final class PageChat: NSView, PaneTabRowSharing, PaneParkableContent {
        let row = AgentPaneTabRow()
        let tools: CGFloat
        private var lastOffer: (height: CGFloat, inset: CGFloat)?
        private var pending: [CGFloat] = []

        init(tools: CGFloat) {
            self.tools = tools
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

        func setTabRow(height: CGFloat, trailingInset: CGFloat) {
            if let lastOffer, lastOffer.height == height, lastOffer.inset == trailingInset { return }
            lastOffer = (height, trailingInset)
            // As header/tabRow.ts answers: a row offered anew gets the width, with no 0 first; a row's end gets 0.
            pending = height > 0 ? [tools] : [0]
        }

        /// The page loaded again (a discarded page shown, a reload): it draws no tools until the row is offered again.
        func reload() {
            row.pageLoaded()
            lastOffer = nil
        }

        /// The page's next report; false when it has none left.
        @discardableResult func deliver() -> Bool {
            guard !pending.isEmpty else { return false }
            row.report(width: pending.removeFirst())
            return true
        }
    }

    /// A terminal or a New Tab page: under the strip, parked in place.
    final class Other: NSView, PaneParkableContent {}

    struct Pane {
        let view: PaneContentView
        let toolbar: PaneToolbar
        let chat: PageChat
        var others: [TabID: Other]
        let window: NSWindow
    }

    private func settle(_ pane: PaneContentView) {
        for _ in 0..<4 {
            pane.needsLayout = true
            pane.layoutSubtreeIfNeeded()
        }
    }

    /// Lays the pane out after each of the chat page's reports and returns the frames seen at every step: no step may
    /// differ from the first.
    private func steps(_ pane: Pane) -> [Frames] {
        var seen = [Frames(pane)]
        settle(pane.view)
        seen.append(Frames(pane))
        while pane.chat.deliver() {
            settle(pane.view)
            seen.append(Frames(pane))
        }
        return seen
    }

    /// What must hold still: where the tabs end (the toolbar's slot begins), and the chat's place in the window while it shows.
    struct Frames: Equatable, CustomStringConvertible {
        let stripEnd: CGFloat
        let chat: NSRect?
        @MainActor init(_ pane: Pane) {
            stripEnd = pane.view.stripView.frame.maxX
            chat = pane.view.content === pane.chat ? pane.chat.convert(pane.chat.bounds, to: nil) : nil
        }

        var description: String { "strip end \(stripEnd), chat \(chat.map { NSStringFromRect($0) } ?? "hidden")" }
    }

    private func select(_ id: String, in pane: inout Pane) {
        let tab = TabID(id)
        pane.view.stripView.model.selectedID = tab
        if id == "chat" {
            pane.toolbar.update(target: id, kind: nil, paneKinds: [.terminal, .newTab])
            pane.view.show(pane.chat)
        } else {
            pane.toolbar.update(target: id, kind: id == "new" ? .newTab : .terminal, paneKinds: [.terminal, .newTab])
            pane.view.show(pane.others[tab])
        }
    }

    /// GitHub (a terminal here), a chat and New Tab, as in his recording; each was selected once, the chat last.
    private func pane(width: CGFloat) -> Pane {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let items = [TabItem(id: TabID("github"), title: "GitHub"), TabItem(id: TabID("chat"), title: "studio-mac/menubar-chats-menu"),
                     TabItem(id: TabID("new"), title: "New Tab")]
        let view = PaneContentView(stripModel: TabStripModel(tabs: items, selectedID: TabID("chat")), reveal: LaunchReveal(deadline: .zero))
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        view.toolbar = toolbar
        view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        window.contentView?.addSubview(view)
        var pane = Pane(view: view, toolbar: toolbar, chat: PageChat(tools: 150),
                        others: [TabID("github"): Other(), TabID("new"): Other()], window: window)
        for id in ["chat", "github", "new", "chat"] {
            select(id, in: &pane)
            _ = steps(pane)
        }
        return pane
    }

    @Test(arguments: [360, 480, 640, 900, 1400])
    func selectingOpeningAndClosingTabsMovesNothingInTheRow(width: Int) {
        var pane = pane(width: CGFloat(width))
        defer { pane.window.orderOut(nil); pane.window.close() }
        let start = Frames(pane)
        // Select: New Tab, GitHub, the chat again.
        for id in ["new", "github", "chat"] {
            select(id, in: &pane)
            for frames in steps(pane) {
                #expect(frames.stripEnd == start.stripEnd, "selecting \(id) at \(width)pt: \(frames) vs \(start)")
                if frames.chat != nil { #expect(frames.chat == start.chat, "the chat moved selecting \(id) at \(width)pt: \(frames)") }
            }
        }
        // Close: New Tab selected and closed, the chat selected after it (the recording).
        select("new", in: &pane)
        _ = steps(pane)
        pane.view.stripView.model.tabs.removeAll { $0.id == TabID("new") }
        pane.others[TabID("new")] = nil
        select("chat", in: &pane)
        for frames in steps(pane) {
            #expect(frames.stripEnd == start.stripEnd, "closing New Tab at \(width)pt: \(frames) vs \(start)")
            #expect(frames.chat == start.chat, "closing New Tab at \(width)pt, the chat moved: \(frames) vs \(start)")
        }
        // Open: a new terminal tab, selected.
        pane.view.stripView.model.tabs.append(TabItem(id: TabID("term2"), title: "Terminal"))
        pane.others[TabID("term2")] = Other()
        select("term2", in: &pane)
        for frames in steps(pane) {
            #expect(frames.stripEnd == start.stripEnd, "opening a tab at \(width)pt: \(frames) vs \(start)")
        }
    }

    /// A chat whose page loads again (shown after it was discarded) stays over the row until it reports, and a row offered
    /// anew moves nothing; tools that leave the row (a replay) give it back to the tabs.
    @Test(arguments: [360, 640, 1400])
    func aChatBetweenReportsStaysInTheRow(width: Int) {
        var pane = pane(width: CGFloat(width))
        defer { pane.window.orderOut(nil); pane.window.close() }
        let start = Frames(pane)
        select("github", in: &pane)
        _ = steps(pane)
        pane.chat.reload()
        select("chat", in: &pane)
        for frames in steps(pane) { #expect(frames == start, "at \(width)pt after a reload: \(frames) vs \(start)") }
        // Another inset (the toolbar changed), then the pane's own again.
        pane.chat.setTabRow(height: pane.view.shownStripHeight, trailingInset: 99)
        for frames in steps(pane) { #expect(frames == start, "at \(width)pt on a new offer: \(frames) vs \(start)") }
        // The tools leave (a replay): the tabs take the row back, the chat under the strip.
        pane.chat.row.report(width: 0)
        settle(pane.view)
        let left = Frames(pane)
        #expect(left.chat.map { $0.height < (start.chat?.height ?? 0) } == true, "tools that left keep the chat over the row: \(left)")
    }
}
