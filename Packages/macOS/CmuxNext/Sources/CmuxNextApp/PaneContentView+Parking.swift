import AppKit
public import CmuxNextAgentPane
import CmuxNextBrowser
public import CmuxNextDesign
import CmuxNextTerminal

/// Content a pane keeps in place, hidden, while another tab shows (browser
/// perf phase 2, cx-asb1; terminals, perf-tabs I6). Taking a browser's chrome
/// out of the window and back costs AppKit tens of ms on each tab switch (its
/// constraints and controls leave and join the window's layout engine, and a
/// Chromium page re-adds its child window). A hidden view stops drawing, takes
/// no events and is not in the accessibility tree; the content lifecycle
/// (`TabContentCache.conceal`) stops the page or surface rendering.
@MainActor
protocol PaneParkableContent: NSView {}

extension BrowserChromeView: PaneParkableContent {}
extension TerminalHostView: PaneParkableContent {}
/// An agent page (a chat or New Tab page) too: putting a WKWebView back into a window waits
/// synchronously for its web process (170-215 ms on Cmd-W back to a New Tab page, #20516).
extension AgentPaneView: PaneParkableContent, PaneTabRowSharing {}
/// An internal page (Markdown, a file viewer, Settings) is a WKWebView too: taking it out of the window
/// and back on every switch re-attached its web process the same way (tab-switch-fast). Its view
/// lives as long as its tab (`InternalPageTabStore.close` removes it), so parking costs no memory. Its
/// page's tools share the tab row (the docked Home's Chief tools, `HomeDockSwitchView+TabRow`).
extension InternalPageView: PaneParkableContent, PaneTabRowForwarding { var tabRowSharer: PaneTabRowSharing? { content as? PaneTabRowSharing } }
/// Its page's rows in the pane's more menu (the docked Home's Chief Actions, `ChiefPaneTools`).
extension InternalPageView: PaneMoreMenuContributing {
    func paneMoreMenuItems() -> [NSMenuItem] { (content as? PaneMoreMenuContributing)?.paneMoreMenuItems() ?? [] }
}

/// One parked view, weak: the content cache owns it.
struct ParkedContent {
    weak var view: NSView?
}

/// What bounds the parked set is not a count: every parked view is the live content of a tab in this
/// pane (`PaneController.dropClosedParked` drops a closed, moved or replaced one on each strip update),
/// and what it costs is held by its owner anyway: an evicted terminal leaves the window with its surface
/// (`TabContentCache.evict`), a hibernated page keeps only its picture. A count cap (8) made a pane with
/// more tabs than that pay a window move on every switch of a cycle: held Ctrl-Tab over 10 or 30 tabs
/// evicted each view 8 switches before its turn came back (pane-tab-switch-fast).
extension PaneContentView {

    /// Puts `view` on screen as the pane's content: unhides it when it is parked here, else adds it (also from another
    /// pane, a moved tab). `leaving`, retired right after, does not count as content above it.
    func install(_ view: NSView, replacing leaving: NSView? = nil) {
        // In a key hold a row-sharing chat keeps its parked frame top-held (its row above the area); otherwise (bottom-held, or
        // from another pane) it joins the held rect rowless, unsized until the landing sizes it once (S1B, Codex #34247).
        let local = view.superview === contentHost, held = contentHost.isHolding, topHeld = local && contentHost.hold?.bottom == false
        if held, !topHeld, let row = view as? PaneTabRowSharing { row.setTabRow(height: 0, trailingInset: 0) }
        guard local else {
            view.frame = contentHost.contentBounds(for: view)
            view.autoresizingMask = held && parkedFrame(of: view) != nil ? [] : [.width, .height]
            contentHost.addSubview(view)
            refreshNativeToolOwner()
            // Parked in the pane it came from.
            if view is PaneParkableContent { view.isHidden = false }
            return
        }
        parked.removeAll { $0.view == nil || $0.view === view }
        if let frame = parkedFrame(of: view), held ? topHeld : view.frame == frame && frame != contentHost.bounds {
            // A chat at the frame it shows at (`show`) keeps it: the pane's next layout moves the host under the tab
            // row and puts the chat at its origin, same size (sized to the host first, its page jumped as it showed).
            view.autoresizingMask = []
            needsLayout = true
        } else {
            if view.frame != contentHost.contentBounds(for: view) { view.frame = contentHost.contentBounds(for: view) }
            view.autoresizingMask = held && parkedFrame(of: view) != nil ? [] : [.width, .height]
        }
        // Above what still shows (a backdrop or a held page); hidden parked
        // views stay where they are, so a switch moves no view.
        let subviews = contentHost.subviews
        if let mine = subviews.firstIndex(of: view),
           let above = subviews.lastIndex(where: { !$0.isHidden && $0 !== view && $0 !== leaving }), above > mine {
            contentHost.addSubview(view, positioned: .above, relativeTo: subviews[above])
        }
        if view is PaneParkableContent { view.isHidden = false }
    }

    /// The pane stops showing `view`: a terminal, browser, agent or internal page stays here, hidden; other
    /// content leaves the pane. A view another pane took is not touched.
    func retire(_ view: NSView) {
        guard view.superview === contentHost else { return }
        (view as? AgentPaneView)?.onNativeToolOwnerChange = nil
        (view as? AgentPaneView)?.onNativeToolMenuRequested = nil
        guard view is PaneParkableContent else {
            view.removeFromSuperview()
            refreshNativeToolOwner()
            return
        }
        // The keyboard never stays in a view that does not show: the window
        // takes it, and the focus model re-applies its target (the content
        // shown now), as when a view leaves the window.
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
        (view as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        view.isHidden = true
        // Parked content keeps its frame and lays nothing out while hidden (S7b): it is sized as it shows (`install`,
        // `show`), and an agent page's paint hold waits for its redraw there (`AgentPageRedraw.awaits`).
        view.autoresizingMask = []
        parked.removeAll { $0.view == nil || $0.view === view }
        parked.append(ParkedContent(view: view))
        prunePark()
    }

    /// Drops parked views that are gone, moved to another pane, or not
    /// `live` (a closed tab, a replaced view).
    func prunePark(live: ((NSView) -> Bool)? = nil) {
        parked.removeAll { entry in
            guard let view = entry.view else { return true }
            guard view.superview === contentHost else {
                if view.superview == nil {
                    (view as? AgentPaneView)?.onNativeToolOwnerChange = nil
                    (view as? AgentPaneView)?.onNativeToolMenuRequested = nil
                }
                return true
            }
            guard view !== content else { return true }
            guard live?(view) ?? true else {
                (view as? AgentPaneView)?.onNativeToolOwnerChange = nil
                (view as? AgentPaneView)?.onNativeToolMenuRequested = nil
                view.removeFromSuperview()
                refreshNativeToolOwner()
                return true
            }
            return false
        }
    }

    /// The frame, in the content host, a parked page that shares the tab row (a chat) shows at: the whole pane when its
    /// tools fit the row, as `layout()` places it, else the area under the strip; nil for any other view. The host is the
    /// area under the strip while a terminal or browser shows: a chat sized with it laid out twice per switch (#23743).
    func parkedFrame(of view: NSView) -> NSRect? {
        guard view is PaneParkableContent, let row = view as? PaneTabRowSharing else { return nil }
        let strip = stripHeight
        let room = bounds.width - toolbarWidth(shown: strip)
        let shares = barPosition == .top && !hidesStrip && strip > 0 && row.drawsInTabRow(room: room)
        let shown = shares ? bounds : NSRect(x: 0, y: barPosition == .top ? strip : 0, width: bounds.width,
                                             height: max(0, bounds.height - strip))
        return contentHost.convert(shown, from: self)
    }

    /// Keeps a hidden internal page that shows a web page at its show frame (`parkedFrame`), from `layout()`: shown at
    /// another size it would show its last frame until it laid out, with no hold.
    func layoutParked() {
        for entry in parked {
            guard let page = entry.view as? InternalPageView, page.superview === contentHost, page !== content, page.isHidden,
                  page.showsWebPage, let frame = parkedFrame(of: page) else { continue }
            if page.frame != frame { page.frame = frame }
        }
    }

    /// Parked content whose tab closed, moved away or got a new view leaves the window. `liveContent`: the pane's tabs' content
    /// now (every kind: a page tab that parks is never dropped as closed); a browser tab keeps the pane's one browser chrome.
    func dropClosedParked(liveContent: () -> [TabContent]) {
        guard !parked.isEmpty else { return }
        let live = Set(liveContent().map { if case .browser = $0, let chrome = browserChrome.chrome { ObjectIdentifier(chrome) } else { ObjectIdentifier($0.view) } })
        prunePark { live.contains(ObjectIdentifier($0)) }
    }

    /// Takes every parked view out of the pane (the pane goes away).
    func dropParked() {
        prunePark { _ in false }
    }
}
