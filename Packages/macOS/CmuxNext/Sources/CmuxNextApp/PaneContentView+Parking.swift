import AppKit
public import CmuxNextAgentPane
import CmuxNextBrowser
public import CmuxNextDesign
import CmuxNextTerminal

/// Content a pane keeps in place, out of sight, while another tab shows (browser
/// perf phase 2, cx-asb1; terminals, perf-tabs I6). Taking a browser's chrome
/// out of the window and back costs AppKit tens of ms on each tab switch (its
/// constraints and controls leave and join the window's layout engine, and a
/// Chromium page re-adds its child window). A parked view stops drawing, takes
/// no events and is not in the accessibility tree; the content lifecycle
/// (`TabContentCache.conceal`) stops the page or surface rendering.
@MainActor
protocol PaneParkableContent: NSView {
    /// Parks the view in place or shows it again (`park`).
    func setParked(_ parked: Bool)
    /// Parked here now.
    var isParkedInPane: Bool { get }
}

extension PaneParkableContent {
    /// A web page hides for AppKit: its WebKit tracking areas, accessibility and key views are not
    /// ours to switch off.
    func setParked(_ parked: Bool) { isHidden = parked }
    var isParkedInPane: Bool { isHidden }
}

extension BrowserChromeView: PaneParkableContent {}
/// A terminal parks by its layer (`LayerParkable`): an AppKit hidden-state change of content under
/// the transparent titlebar re-sends the window's titlebar drag shapes, and the next commit waits on
/// a window-server fence (cx-8w027.19, one per tab switch).
/// A host that shows a control of its own (`parksByLayer` false) parks by AppKit's hidden state.
extension TerminalHostView: PaneParkableContent {
    func setParked(_ parked: Bool) {
        if parked, !parksByLayer {
            isParked = false
            isHidden = true
        } else {
            if isHidden { isHidden = false }
            isParked = parked
        }
    }
    var isParkedInPane: Bool { isParked || isHidden }
}
/// An agent page (a chat or New Tab page) too: putting a WKWebView back into a window waits
/// synchronously for its web process (170-215 ms on Cmd-W back to a New Tab page, #20516).
extension AgentPaneView: PaneParkableContent, PaneTabRowSharing {}

/// The pane's content host: a parked subview (`LayerParkable`) is out of hit testing and out of the
/// accessibility tree, as a hidden one is.
final class PaneContentHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, NSMouseInRect(point, frame, superview?.isFlipped ?? false) else { return nil }
        let local = convert(point, from: superview)
        for subview in subviews.reversed() where (subview as? LayerParkable)?.isParked != true {
            if let hit = subview.hitTest(local) { return hit }
        }
        return self
    }

    override func accessibilityChildren() -> [Any]? {
        super.accessibilityChildren()?.filter { child in
            guard let view = child as? NSView else { return true }
            return !view.isOutOfSight
        }
    }
}

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
        guard view.superview === contentHost else {
            view.frame = contentHost.bounds
            view.autoresizingMask = [.width, .height]
            contentHost.addSubview(view)
            // Parked in the pane it came from.
            (view as? PaneParkableContent)?.setParked(false)
            return
        }
        parked.removeAll { $0.view == nil || $0.view === view }
        if view.frame != contentHost.bounds { view.frame = contentHost.bounds }
        view.autoresizingMask = [.width, .height]
        // Above what still shows (a backdrop or a held page); hidden parked
        // views stay where they are, so a switch moves no view.
        let subviews = contentHost.subviews
        if let mine = subviews.firstIndex(of: view),
           let above = subviews.lastIndex(where: { !(($0 as? PaneParkableContent)?.isParkedInPane ?? $0.isHidden) && $0 !== view && $0 !== leaving }), above > mine {
            contentHost.addSubview(view, positioned: .above, relativeTo: subviews[above])
        }
        (view as? PaneParkableContent)?.setParked(false)
    }

    /// The pane stops showing `view`: a terminal, browser or agent page stays here, hidden; other
    /// content leaves the pane. A view another pane took is not touched.
    func retire(_ view: NSView) {
        guard view.superview === contentHost else { return }
        guard let parkable = view as? PaneParkableContent else {
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
        parkable.setParked(true)
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
            guard let view = entry.view, view.superview === contentHost, view !== content else { return true }
            guard live?(view) ?? true else {
                view.removeFromSuperview()
                return true
            }
            return false
        }
        while parked.count > Self.parkLimit {
            let oldest = parked.removeFirst()
            if let view = oldest.view, view.superview === contentHost, view !== content { view.removeFromSuperview() }
        }
    }

    /// Takes every parked view out of the pane (the pane goes away).
    func dropParked() {
        prunePark { _ in false }
    }
}
