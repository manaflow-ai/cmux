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

/// The outcome of parsing a `--tab` option into a ``SidebarMutationTabTarget``.
///
/// At most one of ``target`` and ``error`` is non-`nil`. A `nil` target paired
/// with a non-`nil` error is the caller's signal to return the error string
/// verbatim, preserving the legacy wire responses.
public struct SidebarMutationTabTargetResolution: Sendable, Equatable {
    /// The parsed target, or `nil` when the `--tab` option was malformed.
    public let target: SidebarMutationTabTarget?
    /// The error string to return verbatim, or `nil` on success.
    public let error: String?

    /// Creates a resolution from a parsed target and/or an error string.
    /// - Parameters:
    ///   - target: The parsed target, or `nil` on failure.
    ///   - error: The verbatim error string, or `nil` on success.
    public init(target: SidebarMutationTabTarget?, error: String?) {
        self.target = target
        self.error = error
    }
}
