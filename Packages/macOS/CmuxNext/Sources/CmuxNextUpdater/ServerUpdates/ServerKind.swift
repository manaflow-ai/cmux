import Foundation

/// A server the cmux-next app talks to and can restart apart from the app itself
/// (plans/cmux-next/server-updates-DESIGN.md).
public nonisolated enum ServerKind: String, Sendable, Codable, CaseIterable {
    /// The cmux-tui daemon: terminals, workspaces and layouts.
    case cmuxTUI = "cmux-tui"
    /// The acpmux daemon: agent sessions.
    case acpmux

    /// The product name shown in notices; never localized.
    public var displayName: String { rawValue }
}
