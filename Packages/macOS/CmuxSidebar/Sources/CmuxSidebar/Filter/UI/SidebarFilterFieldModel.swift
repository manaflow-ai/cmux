public import Foundation

/// Immutable render input for the sidebar's filter field.
///
/// A value snapshot, not a store: the field sits above a virtualized list, and
/// the sidebar's snapshot-boundary rule keeps observable references out of
/// everything in that subtree.
public struct SidebarFilterFieldModel: Sendable, Equatable {
    /// The text currently in the field.
    public let queryText: String
    /// How many workspaces match.
    public let matchCount: Int
    /// How many workspaces exist in total.
    public let totalCount: Int
    /// The field the query is scoped to by a sigil, if any.
    public let scopeField: SidebarFilterField?

    /// Whether the field has anything in it.
    public var hasQuery: Bool {
        !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a real query matched nothing.
    public var isEmptyResult: Bool {
        hasQuery && matchCount == 0
    }

    /// Whether to show the match count.
    ///
    /// Hidden when the query matches everything, because "42 of 42" is noise;
    /// the count earns its place once it is narrowing something. Zero counts
    /// as narrowing: watching the number fall to 0 is how the field reports a
    /// miss, with no colour change needed anywhere.
    public var showsMatchCount: Bool {
        hasQuery && matchCount < totalCount
    }

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - queryText: Text currently in the field.
    ///   - matchCount: Number of matching workspaces.
    ///   - totalCount: Number of workspaces in the sidebar.
    ///   - scopeField: Field the query is scoped to, if a sigil was typed.
    public init(
        queryText: String,
        matchCount: Int,
        totalCount: Int,
        scopeField: SidebarFilterField? = nil
    ) {
        self.queryText = queryText
        self.matchCount = matchCount
        self.totalCount = totalCount
        self.scopeField = scopeField
    }
}
