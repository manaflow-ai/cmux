import CmuxNextWakeups
import Foundation

extension PageWebView {
    /// Runs `body` once the current document has painted its first frame
    /// (``PagePaintProbe``), now if it has. A pane keeps its outgoing content
    /// until then (no-flicker audit).
    public func whenPainted(_ body: @escaping () -> Void) {
        if hasPainted { body() } else { paintWaiters.append(body) }
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
