public import Foundation

/// The outcome of parsing an optional `--panel`/`--surface` id option.
///
/// Produced by ``SidebarMetadataArgumentParser/parseOptionalPanelId(options:usage:)``.
/// At most one of ``panelId`` and ``error`` is non-`nil`. A `nil` panel id with a
/// `nil` error means the option was absent (which is valid); a non-`nil` error is
/// returned verbatim by the caller to preserve the legacy wire responses.
public struct SidebarOptionalPanelId: Sendable, Equatable {
    /// The parsed panel id, or `nil` when the option was absent or malformed.
    public let panelId: UUID?
    /// The verbatim error string, or `nil` when the option was absent or valid.
    public let error: String?

    /// Creates a result from a parsed panel id and/or an error string.
    /// - Parameters:
    ///   - panelId: The parsed panel id, or `nil`.
    ///   - error: The verbatim error string, or `nil`.
    public init(panelId: UUID?, error: String?) {
        self.panelId = panelId
        self.error = error
    }
}
