import Foundation

/// Stores prompt-submit turn-start anchors by workspace and optional surface.
struct PromptSubmitOpenAnchorStore {
    private var anchors: [TabSurfaceKey: TerminalNotificationOpenAnchor] = [:]

    /// Returns whether the store has no recorded anchors.
    var isEmpty: Bool {
        anchors.isEmpty
    }

    /// Records a turn-start anchor for a workspace and optional surface.
    ///
    /// - Parameters:
    ///   - anchor: Absolute terminal turn-start anchor captured at prompt submit time.
    ///   - tabId: Workspace identifier that owns the terminal surface.
    ///   - surfaceId: Terminal surface or panel identifier within the workspace.
    mutating func record(
        _ anchor: TerminalNotificationOpenAnchor,
        forTabId tabId: UUID,
        surfaceId: UUID?
    ) {
        anchors[TabSurfaceKey(tabId: tabId, surfaceId: surfaceId)] = anchor
    }

    /// Returns the best turn-start anchor for a workspace and optional surface.
    ///
    /// - Parameters:
    ///   - tabId: Workspace identifier that owns the notification.
    ///   - surfaceId: Terminal surface or panel identifier for the notification.
    /// - Returns: A surface-specific anchor, or the tab-level fallback when available.
    func anchor(forTabId tabId: UUID, surfaceId: UUID?) -> TerminalNotificationOpenAnchor? {
        let target = TabSurfaceKey(tabId: tabId, surfaceId: surfaceId)
        if let anchor = anchors[target] {
            return anchor
        }
        guard surfaceId != nil else { return nil }
        return anchors[TabSurfaceKey(tabId: tabId, surfaceId: nil)]
    }

    /// Removes anchors for a tab and the supplied surface aliases.
    ///
    /// - Parameters:
    ///   - tabId: Workspace identifier whose anchors should be pruned.
    ///   - surfaceIds: Surface, panel, or Bonsplit alias identifiers to remove.
    ///   - removesNilFallback: Whether to remove the tab-level fallback anchor.
    mutating func remove(
        forTabId tabId: UUID,
        surfaceIds: Set<UUID>,
        removesNilFallback: Bool
    ) {
        anchors = anchors.filter { entry in
            guard entry.key.tabId == tabId else { return true }
            guard let surfaceId = entry.key.surfaceId else {
                return !removesNilFallback
            }
            return !surfaceIds.contains(surfaceId)
        }
    }

    /// Removes all anchors associated with a workspace.
    ///
    /// - Parameter tabId: Workspace identifier whose anchors should be removed.
    mutating func removeAll(forTabId tabId: UUID) {
        anchors = anchors.filter { entry in
            entry.key.tabId != tabId
        }
    }

    /// Moves a surface anchor from one workspace to another.
    ///
    /// - Parameters:
    ///   - sourceTabId: Workspace identifier that currently owns the anchor.
    ///   - destinationTabId: Workspace identifier that should receive the anchor.
    ///   - surfaceId: Surface identifier being rebound.
    mutating func rebindSurface(
        fromTabId sourceTabId: UUID,
        toTabId destinationTabId: UUID,
        surfaceId: UUID
    ) {
        let sourceKey = TabSurfaceKey(tabId: sourceTabId, surfaceId: surfaceId)
        guard let anchor = anchors.removeValue(forKey: sourceKey) else { return }
        let destinationKey = TabSurfaceKey(tabId: destinationTabId, surfaceId: surfaceId)
        if anchors[destinationKey] == nil {
            anchors[destinationKey] = anchor
        }
    }

    /// Removes every recorded prompt-submit anchor.
    mutating func removeAll() {
        anchors.removeAll()
    }
}
