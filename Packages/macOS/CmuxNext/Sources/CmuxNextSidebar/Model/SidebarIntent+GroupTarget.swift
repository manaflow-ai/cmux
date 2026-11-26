extension SidebarIntent {
    /// The group a personal-state write of this intent names: the group it edits, moves into, folds, pins or removes.
    /// nil for an intent that writes no existing group (a create, the editor closing, a reopen, the rest) and for a
    /// group close, which reads its group's shown rows to close them.
    public var writtenGroup: GroupID? {
        switch self {
        case let .move(_, group), let .reorderGroup(group, _), let .renameGroup(group, _), let .setGroupColor(group, _),
             let .ungroup(group), let .setGroupPinned(group, _), let .setGroupIcon(group, _), let .toggleCollapse(.group(group)):
            group
        default:
            nil
        }
    }

    /// This intent naming group `id` where it named ``writtenGroup`` (the daemon's id for a group the sidebar made
    /// under its own). Any other intent as it is.
    public func writing(group id: GroupID) -> SidebarIntent {
        switch self {
        case let .move(ids, _): .move(ids, toGroup: id)
        case let .reorderGroup(_, index): .reorderGroup(id, index: index)
        case let .renameGroup(_, name): .renameGroup(id, name)
        case let .setGroupColor(_, color): .setGroupColor(id, color)
        case .ungroup: .ungroup(id)
        case let .setGroupPinned(_, pinned): .setGroupPinned(id, pinned)
        case let .setGroupIcon(_, icon): .setGroupIcon(id, icon)
        case .toggleCollapse(.group): .toggleCollapse(.group(id))
        default: self
        }
    }

    /// Whether the rows can show this intent as a pending edit (`SidebarPendingEdits`, applied again on every
    /// recompute): a toggle or a pin would flip or move again each time, so those show when they are sent.
    public var showsAsPendingEdit: Bool {
        switch self {
        case .toggleCollapse, .setGroupPinned: false
        default: true
        }
    }
}
