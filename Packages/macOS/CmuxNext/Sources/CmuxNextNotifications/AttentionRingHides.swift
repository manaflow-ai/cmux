package import CmuxNextDaemon
import Observation

/// The agent requests (tab-attention-v1) whose pane ring the person hid, by going into the tab or Dismiss Highlight.
///
/// A request stays hidden as itself, not as one tab model: a pane moved to another workspace gets a new tab model, and
/// a resync lays the same record again, and neither is a new request, so neither rings again. A request with an
/// owner id is kept per owning tab (``NotificationOwnerKey``); an older daemon's mark has no id, so only the tab
/// model's own generation can say it is still the mark hidden.
///
/// ```swift
/// let hides = AttentionRingHides()
/// hides.hide(tab, owner: key)          // a click into the marked pane
/// hides.isHidden(tab, owner: key)      // true until the agent asks again
/// ```
@MainActor
@Observable
package final class AttentionRingHides {
    /// The hidden request id per owning tab.
    private var requests: [NotificationOwnerKey: String] = [:]

    package init() {}

    /// Hides the ring of `tab`'s current request, owned as `owner`. Hides of the same machine's earlier daemon
    /// sessions go: that daemon numbers its tabs anew.
    package func hide(_ tab: TabModel, owner: NotificationOwnerKey) {
        guard let attention = tab.attention else { return }
        tab.attentionRingHiddenThrough = tab.attentionGeneration
        guard let request = attention.requestID else { return }
        if requests.keys.contains(where: { $0.machine == owner.machine && $0.session != owner.session }) {
            requests = requests.filter { $0.key.machine != owner.machine || $0.key.session == owner.session }
        }
        if requests[owner] != request { requests[owner] = request }
    }

    /// Whether the person hid the ring of `tab`'s current request, owned as `owner`.
    package func isHidden(_ tab: TabModel, owner: NotificationOwnerKey) -> Bool {
        guard let attention = tab.attention else { return false }
        guard let request = attention.requestID else { return tab.attentionRingHiddenThrough == tab.attentionGeneration }
        return requests[owner] == request
    }
}
