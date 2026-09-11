#if os(iOS)
import CmuxMobileShell

/// Keeps a one-time workspace-changes hint stable across transient transport
/// state changes while still allowing an eligible detail view to arm it.
enum WorkspaceChangesHintRefreshPolicy {
    /// Returns the hint that should remain mounted after an eligibility update.
    ///
    /// A disconnect temporarily makes the capability gate unavailable. That
    /// must not erase an already-presented hint, because the reconnect would
    /// otherwise present the same hint again when the gates recover. Once the
    /// detail is available again, however, the candidate is authoritative: a
    /// missing candidate means the workspace no longer has eligible changes.
    static func next(
        current: MobileWorkspaceChangesHint?,
        isAvailable: Bool,
        candidate: MobileWorkspaceChangesHint?
    ) -> MobileWorkspaceChangesHint? {
        guard isAvailable else { return current }
        return candidate
    }
}
#endif
