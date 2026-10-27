package import CmuxNextWakeups

/// The app's pages that take their visibility from their tab's node (``BrowserVisibilityFollowing``, feature
/// `chromiumTabVisibility`, p06-scheduler-212), and a watch of each followed page's capture: the hibernation thaws a
/// frozen page that gains one, as Chrome's freezing policy unfreezes a page that gains a reason not to freeze
/// (components/performance_manager/freezing/freezing_policy.cc `CannotFreezeReason`).
@MainActor package final class BrowserVisibilityFollowers {
    package let isEnabled: Bool
    /// The page's follow control (a seam for tests, as `BrowserHibernation.freezer`).
    package var follower: (any BrowserTab) -> (any BrowserVisibilityFollowing)? = { $0 as? any BrowserVisibilityFollowing }
    private var captureWatches: [String: VisibilitySubscription] = [:]

    package init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Page `page` of tab `key` follows `node` from now, and `onCapture` runs each time a capture vote appears on
    /// `node`. A page with no such call (WebKit, a fork before API 37) follows nothing and is not watched; off, `node`
    /// is not read.
    package func follow(_ key: String, _ page: any BrowserTab, node readNode: @autoclosure () -> VisibilityNode?,
                        onCapture: @escaping @MainActor () -> Void) {
        captureWatches[key] = nil
        guard isEnabled, let tab = follower(page), let node = readNode(),
              tab.followVisibility(of: node, capture: BrowserPageCapture.votes(on:)) else { return }
        captureWatches[key] = node.subscribeExemption(owner: "BrowserHibernation.capture") { [weak node] in
            guard let node, BrowserPageCapture.votes(on: node) != .notCaptured else { return }
            onCapture()
        }
    }

    /// Page `key` follows its tab's node: Chromium hears the node's hide itself, in the node's own turn.
    package func follows(_ key: String) -> Bool { captureWatches[key] != nil }

    package func forget(_ key: String) {
        captureWatches[key] = nil
    }
}
