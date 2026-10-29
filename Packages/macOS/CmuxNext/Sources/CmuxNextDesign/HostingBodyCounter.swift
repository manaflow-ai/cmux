import CmuxNextWakeups

/// Counts SwiftUI body evaluations of one hosting view, by its node's state when they ran
/// (`ObservationLedger.Owner/bodyEvaluated(hidden:)`).
@MainActor public final class HostingBodyCounter {
    var owner: ObservationLedger.Owner?
    weak var node: VisibilityNode?
    private(set) var total = 0
    private(set) var hidden = 0

    init() {}

    /// One body ran. Call it first in a body, which then returns its view: `bodyCounter?.record(); return content`.
    public func record() {
        let isHidden = node?.effective == .hidden
        total += 1
        if isHidden { hidden += 1 }
        owner?.bodyEvaluated(hidden: isHidden)
    }
}
