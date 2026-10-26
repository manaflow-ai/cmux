import CmuxNextSignposts
import CmuxNextWakeups
import Foundation
import WebKit

extension PageWebView {
    /// Runs `body` once the current document has painted its first frame
    /// (``PagePaintProbe``), now if it has. A pane keeps its outgoing content
    /// until then (no-flicker audit).
    public func whenPainted(_ body: @escaping () -> Void) {
        if hasPainted { body() } else { paintWaiters.append(body) }
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

    /// A ``ChatOpenTrace`` mark of this page, when it is an agent chat's page: its `create.tab` instant carries
    /// ``traceID``, so it lines up with this page's `webui.open`.
    func traceMark(_ mark: ChatOpenTrace.Mark) {
        guard descriptor.id == ChatOpenTrace.agentPageID else { return }
        ChatOpenTrace.shared.mark(mark, page: self)
    }
}
