public import Foundation

/// Session-scoped pull-request state attached explicitly by a CLI handoff.
///
/// The store owns the state transitions that are independent of AppKit or the
/// workspace model. App composition decides when to publish the resulting
/// value, while this type keeps attach, watcher reconciliation, and clear
/// semantics in the sidebar package where they can be tested directly.
public struct SidebarManualPullRequestStore: Equatable, Sendable {
    /// The currently attached manual pull request, if any.
    public private(set) var state: SidebarPullRequestState?

    public init(state: SidebarPullRequestState? = nil) {
        self.state = state
    }

    /// Replaces the state with a CLI-owned association.
    @discardableResult
    public mutating func attach(
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String?
    ) -> Bool {
        replace(SidebarPullRequestState(
            number: number,
            label: label,
            url: url,
            status: status,
            branch: branch
        ))
    }

    /// Applies a fresh watcher status to the matching manual association.
    /// The CLI-owned label, URL, and branch remain authoritative.
    @discardableResult
    public mutating func reconcile(with watcherState: SidebarPullRequestState) -> Bool {
        guard let manual = state,
              !watcherState.isStale,
              manual.number == watcherState.number,
              manual.url.absoluteString.lowercased() == watcherState.url.absoluteString.lowercased()
        else {
            return false
        }
        return replace(SidebarPullRequestState(
            number: manual.number,
            label: manual.label,
            url: manual.url,
            status: watcherState.status,
            branch: manual.branch
        ))
    }

    /// Removes the CLI-owned association.
    @discardableResult
    public mutating func clear() -> Bool {
        replace(nil)
    }

    /// Replaces the value for app lifecycle resets and restoration seams.
    @discardableResult
    public mutating func replace(_ nextState: SidebarPullRequestState?) -> Bool {
        guard state != nextState else { return false }
        state = nextState
        return true
    }
}
