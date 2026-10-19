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

/// One parked view, weak: the content cache owns it.
struct ParkedContent {
    weak var view: NSView?
}

extension PaneContentView {
    /// The most terminals, browsers and agent pages one pane keeps hidden. Older ones leave the window
    /// (the old cost, paid once for a tab visited long ago).
    static let parkLimit = 8

    /// Puts `view` on screen as the pane's content: unhides it when it is
    /// parked here, else adds it (also from another pane, a moved tab).
    /// `leaving`, retired right after, does not count as content above it.
    func install(_ view: NSView, replacing leaving: NSView? = nil) {
        if probeWings, let wings = probeWingsView, view.superview === wings {
            parked.removeAll { $0.view == nil || $0.view === view }
            view.frame = contentHost.bounds
            view.autoresizingMask = [.width, .height]
            contentHost.addSubview(view, positioned: .below, relativeTo: wings)
            return
        }
        guard view.superview === contentHost else {
            view.frame = contentHost.bounds
            view.autoresizingMask = [.width, .height]
            contentHost.addSubview(view)
            // Parked in the pane it came from.
            if view is PaneParkableContent { probeSetHidden(view, false) }
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
        if view is PaneParkableContent { probeSetHidden(view, false) }
    }

    /// The pane stops showing `view`: a terminal, browser or agent page stays here, hidden; other
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
        if probeWings {
            if !(view is AgentPaneView) { view.autoresizingMask = [] }
            wingsView().addSubview(view)
            parked.removeAll { $0.view == nil || $0.view === view }
            parked.append(ParkedContent(view: view))
            prunePark()
            return
        }
        probeSetHidden(view, true)
        // A hidden agent page stays sized with the pane, so showing it again needs no redraw at a new
        // size (`AgentPageRedraw.awaits`). Terminals and browsers do no work while hidden: `install`
        // sets their frame.
        if !(view is AgentPaneView) { view.autoresizingMask = [] }
        parked.removeAll { $0.view == nil || $0.view === view }
        parked.append(ParkedContent(view: view))
        prunePark()
    }

    /// Drops parked views that are gone, moved to another pane, past
    /// ``parkLimit``, or not `live` (a closed tab, a replaced view).
    func prunePark(live: ((NSView) -> Bool)? = nil) {
        parked.removeAll { entry in
            guard let view = entry.view, view.superview === contentHost || (probeWingsView != nil && view.superview === probeWingsView), view !== content else { return true }
            guard live?(view) ?? true else {
                view.removeFromSuperview()
                return true
            }
            return false
        }
        while parked.count > Self.parkLimit {
            let oldest = parked.removeFirst()
            if let view = oldest.view, view.superview === contentHost || (probeWingsView != nil && view.superview === probeWingsView), view !== content { view.removeFromSuperview() }
        }
    }

    /// Takes every parked view out of the pane (the pane goes away).
    func dropParked() {
        prunePark { _ in false }
    }
}


/// PROBE ONLY (perf-drag cx-8w027.19, variant d): a parked view hides by its layer, so its NSView never
/// changes hidden state (AppKit re-sends the titlebar drag shapes on a hidden change in the band).
@MainActor private func probeSetHidden(_ view: NSView, _ hidden: Bool) {
    if ProcessInfo.processInfo.environment["CMUX_NEXT_PROBE_VARIANT"] == "d", let layer = view.layer {
        view.isHidden = false
        layer.isHidden = hidden
    } else {
        view.isHidden = hidden
    }
}


/// PROBE ONLY (variant f): parked views live in one hidden container ("wings") that is never shown,
/// so a switch changes no view's own hidden state: it moves the view between two superviews.
extension PaneContentView {
    var probeWings: Bool { ProcessInfo.processInfo.environment["CMUX_NEXT_PROBE_VARIANT"] == "f" }
    var probeWingsView: NSView? { contentHost.subviews.first { $0.identifier?.rawValue == "probe.wings" } }
    func wingsView() -> NSView {
        if let wings = probeWingsView { return wings }
        let wings = NSView(frame: contentHost.bounds)
        wings.identifier = NSUserInterfaceItemIdentifier("probe.wings")
        wings.autoresizingMask = [.width, .height]
        wings.isHidden = true
        contentHost.addSubview(wings)
        return wings
    }
}
