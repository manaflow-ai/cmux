import CmuxNextSignposts
import CmuxNextWakeups
import Foundation

extension PageWebView {
    /// Runs `body` once the current document has painted its first frame
    /// (``PagePaintProbe``), now if it has. A pane keeps its outgoing content
    /// until then (no-flicker audit).
    public func whenPainted(_ body: @escaping () -> Void) {
        if hasPainted { body() } else { paintWaiters.append(body) }
    }

    /// This page's id on the `webui.*` trace tracks (``SignpostName/webuiOpen``): its address while it lives.
    var traceID: UInt64 { UInt64(UInt(bitPattern: ObjectIdentifier(self))) }

    /// Opens the ``SignpostName/webuiOpen`` slice at the first document's load start.
    func traceOpenBegin() {
        openTracePending = true
        Signposter.asyncBegin(.webuiOpen, id: traceID, arg0: engineDecision.engine == .cef ? 1 : 0)
    }

    /// Closes the ``SignpostName/webuiOpen`` slice opened by ``traceOpenBegin()``: at the first paint, or at
    /// `close()` when the page closed before it painted.
    func traceOpenEnd(closedBeforePaint: Bool = false) {
        guard openTracePending else { return }
        openTracePending = false
        Signposter.asyncEnd(.webuiOpen, id: traceID, arg0: closedBeforePaint ? 1 : 0)
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension PageWebView {
    /// A ``ChatOpenTrace`` mark of this page, when it is an agent chat's page.
    func traceMark(_ mark: ChatOpenTrace.Mark) {
        guard ChatOpenTrace.shared.isArmed, descriptor.id == ChatOpenTrace.agentPageID else { return }
        ChatOpenTrace.shared.mark(mark, page: self)
    }
}
#endif
