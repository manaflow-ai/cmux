public import Foundation

/// How a v1 line-protocol workspace argument identifies its target workspace,
/// split out of the app-resident ``ControlWorkspaceContext`` `*V1` witnesses so
/// the pure UUID/index classification has a tested, `Sendable` home while the
/// live `TabManager` lookups and bounds checks stay app-side.
///
/// Both `select_workspace` and `close_workspace` resolve a single positional
/// argument: `select_workspace` accepts a workspace UUID or a zero-based tab
/// index, while `close_workspace` accepts only a UUID. Classification is
/// byte-faithful to the legacy `UUID(uuidString:)`-then-`Int(_:)` precedence (a
/// pure-digit string is never a valid UUID, so the order is observable only for
/// values that parse as exactly one). The downstream guards stay app-side: the
/// `index >= 0 && index < tabs.count` bounds check, the tab lookup, and
/// `close_workspace` rejecting a non-UUID argument with `"ERROR: Invalid tab
/// ID"`.
public enum ControlWorkspaceV1Selector: Sendable, Equatable {
    /// The argument parsed as a workspace UUID.
    case uuid(UUID)

    /// The argument parsed as an integer index (UUID parsing was tried first and
    /// failed). The caller still range-checks it against the live tab count.
    case index(Int)

    /// The argument parsed as neither a UUID nor an integer.
    case unparseable

    /// Classifies a raw v1 workspace argument, trying `UUID(uuidString:)` first
    /// and `Int(_:)` second, matching the legacy `if let uuid … else if let
    /// index …` ordering.
    ///
    /// - Parameter rawArgument: The raw positional argument.
    public init(rawArgument: String) {
        if let uuid = UUID(uuidString: rawArgument) {
            self = .uuid(uuid)
        } else if let index = Int(rawArgument) {
            self = .index(index)
        } else {
            self = .unparseable
        }
    }
}
