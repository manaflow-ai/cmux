public import Foundation

/// The tab addressed by a v1 sidebar mutation command (the typed twin of the
/// legacy file-private `SidebarMutationTabTarget`): the selected tab, a tab by
/// workspace id, or a tab by sidebar index.
public enum ControlSidebarTabTarget: Sendable, Equatable {
    /// The selected tab of the active tab manager (no `--tab` option).
    case selected
    /// A tab addressed by workspace UUID (`--tab=<uuid>`), resolvable across
    /// windows.
    case workspace(UUID)
    /// A tab addressed by sidebar index (`--tab=<index>`) in the active tab
    /// manager.
    case index(Int)
}
