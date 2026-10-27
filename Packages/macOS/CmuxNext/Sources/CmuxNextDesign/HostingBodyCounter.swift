import CmuxNextWakeups
public import SwiftUI

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

extension EnvironmentValues {
    /// The counter of the gated hosting view a view is in (``VisibilityGatedHostingView``); nil elsewhere.
    @Entry public var hostingBodyCounter: HostingBodyCounter?
}

/// The root of a gated hosting view: builds the page's content in its body and counts each evaluation.
struct HostingBodyCountedRoot<Content: View>: View {
    let counter: HostingBodyCounter
    let content: @MainActor () -> Content

    var body: some View {
        counter.record()
        return content().environment(\.hostingBodyCounter, counter)
    }
}
