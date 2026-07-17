/// The decoded result of `mobile.workspace.diffs.context`.
public struct MobileDiffContextResponse: Codable, Sendable, Equatable {
    /// Requested new-side source rows in file order.
    public let rows: [String]

    /// Creates an expanded-context response.
    /// - Parameter rows: Requested new-side source rows in file order.
    public init(rows: [String]) {
        self.rows = rows
    }
}
