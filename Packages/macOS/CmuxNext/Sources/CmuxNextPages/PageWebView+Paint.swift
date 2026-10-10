import Foundation

extension PageWebView {
    /// Runs `body` once the current document has painted its first frame
    /// (``PagePaintProbe``), now if it has. A pane keeps its outgoing content
    /// until then (no-flicker audit).
    public func whenPainted(_ body: @escaping () -> Void) {
        if hasPainted { body() } else { paintWaiters.append(body) }
    }
}
