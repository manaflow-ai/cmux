public import Foundation
import Observation

/// Observable state for browser find-in-page.
///
/// Backs the find-in-page overlay: `needle` is the current query text, `total` is the
/// number of matches highlighted in the document, and `selected` is the zero-based index
/// of the currently selected match (only meaningful when `total` is greater than zero).
/// Both counts are `nil` until a find script has reported a result.
@MainActor
@Observable
public final class BrowserSearchState {
    /// The current find-in-page query text.
    public var needle: String

    /// The zero-based index of the currently selected match, or `nil` when no result has been reported.
    public var selected: UInt?

    /// The number of matches highlighted in the document, or `nil` when no result has been reported.
    public var total: UInt?

    /// Creates find-in-page state seeded with an optional query.
    /// - Parameter needle: The initial query text. Defaults to the empty string.
    public init(needle: String = "") {
        self.needle = needle
    }
}
