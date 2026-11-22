public import Foundation

/// What a Back/Forward step is (BACK-FORWARD-WORKSPACES-ONLY,
/// `navigation.history.scope`).
public nonisolated enum HistoryStepScope: String, Hashable, Sendable, CaseIterable {
    /// A step only when the selected sidebar item changes (a workspace or a
    /// top page); focus changes inside a workspace refresh its entry, so
    /// stepping back returns to the tab and pane it last had focused. Default.
    case workspaces
    /// Every settled tab, pane and page focus is a step (the older behavior).
    case everything

    public static let `default` = HistoryStepScope.workspaces
}

extension HistoryLocation {
    /// Whether two locations are the same sidebar item: the same top page,
    /// or the same workspace on the same machine.
    public func isSameSidebarItem(as other: HistoryLocation) -> Bool {
        if page != nil || other.page != nil { return page == other.page }
        return key.machine == other.key.machine && workspace == other.workspace
    }
}

extension LocationTrail {
    /// Records a settled location as `scope` says: with `workspaces`, a
    /// location in the current entry's sidebar item replaces that entry
    /// (it remembers the last focused tab) instead of adding a step.
    /// Returns true when the trail changed.
    @discardableResult
    public mutating func record(_ location: HistoryLocation, at time: Date, scope: HistoryStepScope) -> Bool {
        if scope == .workspaces, pending == nil, let current, current.location.isSameSidebarItem(as: location) {
            guard current.location != location else { return false }
            replaceCurrent(location)
            return true
        }
        return record(location, at: time)
    }
}
