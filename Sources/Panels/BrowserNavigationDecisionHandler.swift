import Foundation

/// Guarantees that a WebKit navigation policy callback is completed at most once.
///
/// WebKit invokes navigation policy delegates on the main thread and requires
/// the supplied callback to be completed synchronously. Keeping this state in a
/// small synchronous wrapper lets `deinit` cancel an abandoned callback without
/// introducing an async hop that could outlive WebKit's policy decision.
final class BrowserNavigationDecisionHandler<Policy> {
    private var pendingHandler: ((Policy) -> Void)?
    private let fallbackPolicy: Policy
    private let label: String

    init(
        _ decisionHandler: @escaping (Policy) -> Void,
        fallbackPolicy: Policy,
        label: String
    ) {
        pendingHandler = decisionHandler
        self.fallbackPolicy = fallbackPolicy
        self.label = label
    }

    /// Returns a closure view that keeps this guard alive while a policy path is pending.
    var closure: (Policy) -> Void {
        { [self] policy in
            self(policy)
        }
    }

    func callAsFunction(_ policy: Policy) {
        guard let pendingHandler else {
            log("decision callback invoked more than once")
            return
        }
        self.pendingHandler = nil
        pendingHandler(policy)
    }

    deinit {
        guard let pendingHandler else { return }
        log("decision callback was dropped; applying fallback policy")
        pendingHandler(fallbackPolicy)
    }

    private func log(_ message: String) {
        NSLog("Browser navigation decision handler (%@): %@", label, message)
    }
}
