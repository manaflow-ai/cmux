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
/// lives as long as its tab (`InternalPageTabStore.close` removes it), so parking costs no memory.
extension InternalPageView: PaneParkableContent {}

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

    /// Puts `view` on screen as the pane's content: unhides it when it is
    /// parked here, else adds it (also from another pane, a moved tab).
    /// `leaving`, retired right after, does not count as content above it.
    func install(_ view: NSView, replacing leaving: NSView? = nil) {
        guard view.superview === contentHost else {
            view.frame = contentHost.bounds
            view.autoresizingMask = [.width, .height]
            contentHost.addSubview(view)
            // Parked in the pane it came from.
            if view is PaneParkableContent { view.isHidden = false }
            return
        }
        parked.removeAll { $0.view == nil || $0.view === view }
        if view.frame != contentHost.bounds { view.frame = contentHost.bounds }
        view.autoresizingMask = [.width, .height]
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
        guard view is PaneParkableContent else {
            view.removeFromSuperview()
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
        // A hidden agent or internal page stays sized with the pane, so showing it again needs no redraw at a new
        // size (`AgentPageRedraw.awaits`). Terminals and browsers do no work while hidden: `install`
        // sets their frame.
        if !(view is AgentPaneView || view is InternalPageView) { view.autoresizingMask = [] }
        parked.removeAll { $0.view == nil || $0.view === view }
        parked.append(ParkedContent(view: view))
        prunePark()
    }

    /// Drops parked views that are gone, moved to another pane, or not
    /// `live` (a closed tab, a replaced view).
    func prunePark(live: ((NSView) -> Bool)? = nil) {
        parked.removeAll { entry in
            guard let view = entry.view, view.superview === contentHost, view !== content else { return true }
            guard live?(view) ?? true else {
                view.removeFromSuperview()
                return true
            }
            return false
        }
    }

    /// Takes every parked view out of the pane (the pane goes away).
    func dropParked() {
        prunePark { _ in false }
    }
}
