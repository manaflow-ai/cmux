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
/// (no-flicker audit). Content that is not a page has nothing to wait for, a page rebuilt
/// after a discard shows its last picture until it paints (``InternalPageView/rebuilt(under:restore:)``),
/// a page discarded in place draws its hide-time snapshot in the show's turn
/// (``PageWebView/drawsDiscardSnapshot``), and a cold page shows its themed stand-in from the open's
/// turn (``PageWebView/showsStandIn``, feature `pageStandIn`): each is its first frame, so the pane
/// swaps to it at once, as Chrome shows a new tab's base background before the renderer's first frame.
extension InternalPageView: PaneFirstPaintGated {
    public var awaitsFirstPaint: Bool {
        // The content first: its build shows the picture or the stand-in.
        guard let page = content as? PageWebView, picture == nil else { return false }
        return !page.hasPainted && !page.drawsDiscardSnapshot && !page.showsStandIn
    }

    public func whenFirstPainted(_ body: @escaping () -> Void) {
        guard let page = content as? PageWebView else { return body() }
        page.whenPainted(body)
    }
}

extension PaneContentView {
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
            guard keptStrip else { return }
            needsLayout = true // invalidate: the hold that kept the strip ended (the guard above).
            // sync-layout: the strip moves in the swap's own transaction (`PanePaintHold.end`), not a frame later.
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
