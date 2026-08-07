public import Foundation

/// Decides whether a sidebar row's shortcut-hint visibility should use the
/// frozen value captured for a specific tab, or fall back to the live value.
public struct SidebarShortcutHintFreezePolicy {
    public init() {}

    public func resolved(
        live: Bool,
        currentTabId: UUID,
        frozenTabId: UUID?,
        frozenValue: Bool
    ) -> Bool {
        if frozenTabId == currentTabId {
            return frozenValue
        }
        return live
    }
}

/// Decides whether a sidebar may mirror an active native workspace drag.
public struct SidebarWorkspaceDragActivationPolicy: Sendable {
    public init() {}

    /// Group anchors cannot move across windows because moving only the anchor
    /// would dissolve the source group and strand its members.
    public func shouldRejectMirroring(
        isLocalWorkspace: Bool,
        isSourceGroupAnchor: Bool
    ) -> Bool {
        !isLocalWorkspace && isSourceGroupAnchor
    }
}
