import Foundation
import OSLog
import WebKit

nonisolated private let browserNavigationDecisionHandlerLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "BrowserNavigationDecision"
)

/// Guards a WebKit action-policy callback with a cancellation fallback.
typealias BrowserNavigationActionDecisionHandler =
    BrowserNavigationDecisionHandler<WKNavigationActionPolicy>

/// Guards a WebKit response-policy callback with a cancellation fallback.
typealias BrowserNavigationResponseDecisionHandler =
    BrowserNavigationDecisionHandler<WKNavigationResponsePolicy>

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

    /// Creates a guard that forwards the first policy and cancels an abandoned one.
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

    /// Forwards one policy decision and ignores any later completion attempts.
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

    /// Emits a diagnostic without coupling callback cleanup to an actor.
    private func log(_ message: String) {
        browserNavigationDecisionHandlerLogger.error(
            "\(message, privacy: .public) label=\(self.label, privacy: .public)"
        )
    }
}
