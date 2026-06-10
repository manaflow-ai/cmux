/// A predicate over workspace rows, shared by every surface that lists
/// workspaces (the device tree today; the flat list can adopt it next).
///
/// Modeled as an enum so new filters (e.g. pinned, running agents) are added
/// as cases with a `matches` arm, and every menu that offers filters picks up
/// the new case from `CaseIterable`. `.all` is the identity filter.
public enum MobileWorkspaceListFilter: String, CaseIterable, Hashable, Sendable {
    /// No filtering; every workspace matches.
    case all
    /// Only workspaces with unread activity (the iMessage-style unread dot).
    case unread

    /// Whether `workspace` passes this filter.
    /// - Parameter workspace: The workspace row under consideration.
    /// - Returns: `true` when the row should be shown.
    public func matches(_ workspace: MobileWorkspacePreview) -> Bool {
        switch self {
        case .all:
            return true
        case .unread:
            return workspace.hasUnread
        }
    }

    /// Whether this filter actually narrows the list (drives the
    /// filled-vs-outlined filter icon and empty-state copy).
    public var isActive: Bool { self != .all }
}
