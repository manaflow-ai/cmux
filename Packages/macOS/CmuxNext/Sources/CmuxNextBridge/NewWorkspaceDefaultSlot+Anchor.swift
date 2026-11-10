import CmuxNextSettings

extension NewWorkspaceDefaultSlot {
    /// This rule for a create that places itself from the window's current workspace (`fromCurrent`) or not: one that
    /// does not drops the current anchor, except under `afterCurrent` (and `beforeCurrent`), which always places beside it.
    nonisolated public func anchored(fromCurrent: Bool) -> NewWorkspaceDefaultSlot {
        var rule = self
        if !fromCurrent, !placesBesideCurrent { rule.current = nil }
        return rule
    }
}
