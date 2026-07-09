internal import Foundation

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
