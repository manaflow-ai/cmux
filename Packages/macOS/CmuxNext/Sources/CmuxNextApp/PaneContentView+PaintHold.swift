import AppKit
public import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups

/// One that painted and is shown again waits for its frame at the size it
/// shows at (`AgentPageRedraw`).
extension AgentPaneView: PaneFirstPaintGated {
    public var awaitsFirstPaint: Bool { !model.hasPainted || redraw.awaits(self) }

    public func whenFirstPainted(_ body: @escaping () -> Void) {
        guard model.hasPainted else { return model.whenPainted(body) }
        // It may answer from this view's own layout(): the hold ends once the window's pass is done.
        redraw.when(self) { [weak self] in
            if let window = self?.window as? ShellWindow { window.afterLayoutPass(body) } else { body() }
        }
    }
}

/// A page tab: transparent until its document paints, like an agent page
/// (no-flicker audit). Content that is not a page has nothing to wait for.
extension InternalPageView: PaneFirstPaintGated {
    public var awaitsFirstPaint: Bool { (content as? PageWebView).map { !$0.hasPainted } ?? false }

    public func whenFirstPainted(_ body: @escaping () -> Void) {
        guard let page = content as? PageWebView else { return body() }
        page.whenPainted(body)
    }
}

extension PaneContentView {
    /// Re-applies page visibility after an outer alpha hold is released (for example, launch
    /// reveal). Chromium lives in a child window and does not observe that alpha transition.
    func refreshChromiumVisibility() {
        guard let content else { return }
        PageWebView.syncChromiumVisibility(in: content)
    }

    /// Whether `view` replacing `hosted` waits for its first frame.
    func holdsForFirstPaint(_ view: NSView?, replacing hosted: NSView?) -> Bool {
        PanePaintHold.holds(view, replacing: hosted)
    }

    /// `incoming` stays invisible until it paints; `outgoing` stays shown until then.
    /// A strip that hides with this swap stays, and `outgoing` keeps its place under it: the pane changes in
    /// one frame, when the swap shows (cx-f6i7).
    func beginPaintHold(outgoing: NSView, incoming: NSView) {
        if hidesStrip, !stripView.isHidden, !isBandActive, outgoing.frame.height > 0 {
            holdKeepsStrip = true
            // The host is not flipped: a fixed height on the strip's far side.
            outgoing.autoresizingMask = barPosition == .top ? [.width, .maxYMargin] : [.width, .minYMargin]
        }
        paintHold.begin(outgoing: outgoing, incoming: incoming, in: contentHost, release: { [weak self] outgoing in
            guard let self, outgoing.superview === contentHost, outgoing !== content else { return }
            retire(outgoing)
            (outgoing as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        }, ended: { [weak self] in
            // The strip, ring and corners change with the swap, in its transaction.
            guard let self else { return }
            let keptStrip = holdKeepsStrip
            holdKeepsStrip = false
            refreshContentFrame()
            refreshNativeToolOwner()
            guard keptStrip else { return }
            needsLayout = true
            layoutSubtreeIfNeeded()
        })
    }

    /// The strip's drawn height: while a hold keeps it after it hid, its
    /// shown height (the content already takes its place, unseen).
    var shownStripHeight: CGFloat {
        guard holdKeepsStrip, paintHold.kept != nil else { return stripHeight }
        return PaneChromeMetrics.current.resolvedStripHeight(scale: window?.backingScaleFactor ?? 2)
    }

    /// Ends the hold: the outgoing view goes and the incoming one shows, in one frame.
    func endPaintHold() {
        paintHold.end()
    }
}
