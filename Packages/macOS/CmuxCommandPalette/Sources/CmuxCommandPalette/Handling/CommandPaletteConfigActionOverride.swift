import Foundation

/// The `cmux.json`-configured overrides for a built-in palette command, resolved
/// app-side from the config store and handed to
/// ``CommandPaletteCommandListBuildPlan``.
///
/// Only a subset of built-in commands map to a configurable action id (the
/// surface-tab-bar built-ins). When such a mapping exists and the user has
/// configured it, the configured action can hide the command from the palette
/// (`palette == false`) or override its title, subtitle, and search keywords.
/// The host resolves the app's configuration type into this neutral value so the
/// build plan's merge logic stays in the palette domain.
public struct CommandPaletteConfigActionOverride: Sendable, Equatable {
    /// Whether the configured action opts into appearing in the palette. A
    /// `false` value removes the command from the assembled list.
    public let palette: Bool
    /// Configured title; overrides the contribution title when present.
    public let title: String
    /// Configured subtitle; overrides the contribution subtitle when present.
    public let subtitle: String?
    /// Configured search keywords; override the contribution keywords only when
    /// non-empty.
    public let keywords: [String]

    /// Creates a resolved override.
    ///
    /// - Parameters:
    ///   - palette: Whether the configured action appears in the palette.
    ///   - title: Configured title.
    ///   - subtitle: Configured subtitle, if any.
    ///   - keywords: Configured keywords (may be empty).
    public init(
        palette: Bool,
        title: String,
        subtitle: String?,
        keywords: [String]
    ) {
        self.palette = palette
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
    }
}
