import CmuxNextSettings

extension NewWorkspaceDefaultSlot {
    /// The setting puts a new workspace after the current row (`workspaces.newPlacement` `afterCurrent`, the default).
    nonisolated public var placesAfterCurrent: Bool { placement == .afterCurrent }

    /// This rule for a create that places itself from the window's current workspace (`fromCurrent`) or not: one that
    /// does not drops the current anchor, except under `afterCurrent`, which always places after it.
    nonisolated public func anchored(fromCurrent: Bool) -> NewWorkspaceDefaultSlot {
        var rule = self
        if !fromCurrent, placement != .afterCurrent { rule.current = nil }
        return rule
    }
}
