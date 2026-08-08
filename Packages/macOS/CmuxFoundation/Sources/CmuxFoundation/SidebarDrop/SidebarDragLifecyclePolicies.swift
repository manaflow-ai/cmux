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

    /// Resolves the workspace identity that may drive a local drop surface.
    ///
    /// A retained AppKit source session is the lifecycle authority. Window-local
    /// presentation can disappear during sidebar reconstruction, so a live
    /// session may restore its identity only in the window that still owns the
    /// workspace.
    ///
    /// - Parameters:
    ///   - liveSessionWorkspaceId: The process-wide native drag identity.
    ///   - isLocalWorkspace: Whether that workspace still belongs to this window.
    /// - Returns: The live workspace identity when it is local; otherwise `nil`.
    public func resolvedLocalWorkspaceId(
        liveSessionWorkspaceId: UUID?,
        isLocalWorkspace: Bool
    ) -> UUID? {
        guard isLocalWorkspace else { return nil }
        return liveSessionWorkspaceId
    }

    /// Group anchors cannot move across windows because moving only the anchor
    /// would dissolve the source group and strand its members.
    public func shouldRejectMirroring(
        isLocalWorkspace: Bool,
        isSourceGroupAnchor: Bool
    ) -> Bool {
        !isLocalWorkspace && isSourceGroupAnchor
    }
}
