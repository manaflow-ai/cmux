/// Forward-migration of the terminal accessory bar's persisted layout from the
/// original v1 schema (parallel `[Int]` arrays of built-in `rawValue`s) to the
/// unified v2 schema keyed by ``ToolbarItemID``.
///
/// The v1 bar had no custom actions, so migration is a pure relabel: every
/// stored `Int` becomes a ``ToolbarItemID/builtin(_:)``. Crucially this
/// preserves the user's existing order and shown/hidden set exactly — a user who
/// had reordered or hidden shortcuts sees the same bar after upgrading.
public struct ToolbarLayoutMigration: Sendable {
    /// Creates a migration helper.
    public init() {}

    /// Maps a legacy order array of built-in `rawValue`s to unified identifiers,
    /// preserving order.
    /// - Parameter legacy: The persisted v1 `displayOrder` array.
    /// - Returns: The same sequence as ``ToolbarItemID/builtin(_:)`` values.
    public func migratedOrder(legacy: [Int]) -> [ToolbarItemID] {
        legacy.map { .builtin($0) }
    }

    /// Maps a legacy enabled array of built-in `rawValue`s to unified
    /// identifiers, preserving the distinction between "user hid everything"
    /// (empty array) and "first launch" (`nil`).
    /// - Parameter legacy: The persisted v1 `enabled` array, or `nil`.
    /// - Returns: The same set as ``ToolbarItemID/builtin(_:)`` values, or `nil`.
    public func migratedEnabled(legacy: [Int]?) -> [ToolbarItemID]? {
        legacy.map { $0.map { .builtin($0) } }
    }
}
