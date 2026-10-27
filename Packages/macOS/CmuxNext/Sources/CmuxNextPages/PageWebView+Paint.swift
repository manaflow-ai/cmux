import AppKit
import CmuxNextSignposts
import CmuxNextWakeupsDisplay
import Foundation
import WebKit

extension PageWebView {
    /// Runs `body` once the current document has painted its first frame
    /// (``PagePaintProbe``), now if it has. A pane keeps its outgoing content
    /// until then (no-flicker audit).
    public func whenPainted(_ body: @escaping () -> Void) {
        if hasPainted { body() } else { paintWaiters.append(body) }
    }

    /// Covers the page with its stand-in (``PageStandInLayer``: its theme's background and `title`) in this
    /// turn, until the document's first frame (``notePainted()`` takes it off in that callback's turn).
    /// Nothing when the document painted already or a preload cover shows its last frame.
    public func showStandIn(title: String) {
        guard !hasPainted, standIn == nil, let host = layer,
              !subviews.contains(where: { $0 is PagePreloadCoverView }) else { return }
        let made = PageStandInLayer()
        // Over the web view and a Chromium page's view, whichever is added later.
        made.zPosition = 1
        standIn = made
        PageStandInLayer.withoutActions {
            made.frame = bounds
            host.addSublayer(made)
        }
        made.title.string = title
        repaintStandIn()
    }

    /// Whether the stand-in covers the page.
    package var showsStandIn: Bool { standIn != nil }

    /// Takes the stand-in off, in one frame.
    func removeStandIn() {
        guard let standIn else { return }
        self.standIn = nil
        PageStandInLayer.withoutActions { standIn.removeFromSuperlayer() }
    }

    /// Paints the stand-in in the page's current theme, zoom and backing scale.
    func repaintStandIn() {
        guard let standIn else { return }
        // Out of a window it has no scale yet; moving into one repaints it (`viewDidMoveToWindow`).
        standIn.paint(currentTheme(), title: standIn.title.string, zoom: pageZoom, scale: window?.backingScaleFactor ?? 2)
    }

    /// This page's id on the `webui.*` trace tracks (``SignpostName/webuiOpen``): its address while it lives.
    var traceID: UInt64 { UInt64(UInt(bitPattern: ObjectIdentifier(self))) }

    /// The trace id of the page whose WebKit view is `webView`; 0 for a web view that is no page's.
    static func traceID(showing webView: WKWebView) -> UInt64 {
        (webView.superview as? PageWebView)?.traceID ?? 0
    }

    /// A new open of this view (``SignpostName/webuiOpen``): one still pending ends as replaced, and one of
    /// `kind` begins. `constructedSince`, a system uptime, is when a new view's construction began.
    func traceOpenRequested(_ kind: PageOpenKind, constructedSince start: TimeInterval? = nil) {
        traceOpenEnd(.replaced)
        var arg0 = kind.rawValue
        if let start {
            arg0 |= UInt64(max(0, (ProcessInfo.processInfo.systemUptime - start) * 1_000_000)) << 8
        }
        openTracePending = true
        trace.asyncBegin(.webuiOpen, id: traceID, arg0: arg0)
    }

    /// A document load began: it belongs to the pending open (a fallback to WebKit, a refused claim's
    /// reload), else it is an open of `kind` of its own.
    func traceOpenLoadStarted(_ kind: PageOpenKind) {
        guard !openTracePending else { return }
        traceOpenRequested(kind)
    }

    /// Ends the pending ``SignpostName/webuiOpen`` slice with `outcome`.
    func traceOpenEnd(_ outcome: PageOpenOutcome) {
        guard openTracePending else { return }
        openTracePending = false
        trace.asyncEnd(.webuiOpen, id: traceID, arg0: outcome.rawValue)
    }

    /// A stage of the agent chat open this page shows (``chatOpen``), in every build: a page with no open writes
    /// nothing. DEBUG and bench builds also mark the running `debug.chat_open_trace`.
    func traceMark(_ stage: ChatOpenStage) {
        chatOpen?.mark(stage)
        #if DEBUG || CMUX_BENCH_HOOKS
        guard ChatOpenTrace.shared.isArmed, descriptor.id == ChatOpenTrace.agentPageID else { return }
        ChatOpenTrace.shared.mark(stage, page: self)
        #endif
    }
}
