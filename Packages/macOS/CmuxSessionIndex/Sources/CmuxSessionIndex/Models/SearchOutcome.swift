public import Foundation

/// What the popover gets back from a deep session search. `errors` is non-empty
/// when one or more agents failed to read their data source (schema mismatch,
/// file missing, SQL error). UI should surface them so users see why the list
/// looks short or empty rather than thinking nothing matched.
public struct SearchOutcome: Sendable {
    public var entries: [SessionEntry]
    public var errors: [String]

    public init(entries: [SessionEntry], errors: [String]) {
        self.entries = entries
        self.errors = errors
    }
}
