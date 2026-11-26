public import Foundation

/// Which tab a sidebar-metadata mutation or report command addresses.
///
/// Parsed from a command's `--tab` option by ``SidebarMetadataArgumentParser``.
/// Resolving a target to a concrete tab is the app target's responsibility
/// (it owns `Tab`/`TabManager`); this value type only carries the parsed intent.
public enum SidebarMutationTabTarget: Sendable, Equatable {
    /// No `--tab` option was supplied; address the currently selected tab.
    case selected
    /// `--tab=<uuid>`: address the workspace/tab with this identifier, searching
    /// every window if it is not in the local tab manager.
    case workspace(UUID)
    /// `--tab=<n>`: address the tab at this zero-based index in the local tab manager.
    case index(Int)
}
