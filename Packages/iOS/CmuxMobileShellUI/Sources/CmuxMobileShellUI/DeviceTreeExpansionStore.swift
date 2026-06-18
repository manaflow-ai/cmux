import Foundation

/// Persists which device / tag rows are expanded in the device tree, keyed by a
/// stable id, so the tree restores its open/closed shape across launches.
///
/// A pure value type over a `Set<String>` of expanded ids with a string
/// round-trip for `@AppStorage`. Kept in the view layer (an `@AppStorage` string
/// behind this codec); ids are never threaded through rows, so no `@Observable`
/// store crosses the tree's `List`/`DisclosureGroup` boundary.
public struct DeviceTreeExpansionStore: Equatable, Sendable {
    public private(set) var expandedIDs: Set<String>

    public init(expandedIDs: Set<String> = []) {
        self.expandedIDs = expandedIDs
    }

    /// Decode from the `@AppStorage` string (newline-separated ids). Blank lines
    /// are ignored so an empty/whitespace store decodes to no expansion.
    public init(storage: String) {
        let ids = storage
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.expandedIDs = Set(ids)
    }

    /// Encode to the `@AppStorage` string. Sorted for a stable representation so
    /// equal sets always serialize identically.
    public var storage: String {
        expandedIDs.sorted().joined(separator: "\n")
    }

    public func isExpanded(_ id: String) -> Bool {
        expandedIDs.contains(id)
    }

    public mutating func setExpanded(_ id: String, _ expanded: Bool) {
        if expanded {
            expandedIDs.insert(id)
        } else {
            expandedIDs.remove(id)
        }
    }
}
