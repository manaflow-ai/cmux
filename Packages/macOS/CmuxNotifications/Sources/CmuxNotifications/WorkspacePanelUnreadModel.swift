public import Foundation
import Observation

/// Workspace-owned keyed unread state for panels.
@MainActor
@Observable
public final class WorkspacePanelUnreadModel {
    /// Panel identifiers carrying a manual unread indicator.
    public private(set) var panelIds: Set<UUID>

    /// Restored indicators keyed by panel, including their workspace-badge provenance.
    public var restoredIndicators: [UUID: RestoredPanelUnreadIndicator] = [:]

    /// Panels with a restored indicator, tracked independently of manual unread state.
    public var restoredPanelIds: Set<UUID> { Set(restoredIndicators.keys) }

    /// Creates keyed panel unread state.
    ///
    /// - Parameter panelIds: The initial unread panel identifiers.
    public init(panelIds: Set<UUID> = []) {
        self.panelIds = panelIds
    }

    /// Replaces the unread panel identifiers when the value changed.
    ///
    /// - Parameter panelIds: The authoritative replacement set.
    /// - Returns: `true` when the stored value changed.
    @discardableResult
    public func replace(with panelIds: Set<UUID>) -> Bool {
        guard self.panelIds != panelIds else { return false }
        self.panelIds = panelIds
        return true
    }
}
