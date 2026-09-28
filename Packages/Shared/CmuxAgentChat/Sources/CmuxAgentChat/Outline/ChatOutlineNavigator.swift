import Foundation

/// Answers "which turn is on screen" and "where does next/previous go" from
/// resolved prompt rows and the terminal viewport.
///
/// A jump puts a prompt on the viewport's second row (one row of context), so
/// the "reading line" is `viewportTop + 1`: the turn on screen is the last
/// prompt at or above it, and next/previous move to the nearest prompt below
/// or above it. At the live bottom, the newest visible prompt is current.
public struct ChatOutlineNavigator: Sendable, Equatable {
    /// Start row per entry, in entry order; `nil` when the prompt could not be
    /// anchored in the terminal.
    public let anchorRows: [Int?]

    /// Creates a navigator.
    ///
    /// - Parameter anchorRows: Start row per outline entry, in entry order.
    public init(anchorRows: [Int?]) {
        self.anchorRows = anchorRows
    }

    /// The entry whose exchange occupies the viewport.
    ///
    /// - Parameters:
    ///   - viewportTop: Absolute row at the top of the viewport.
    ///   - viewportRows: Visible row count.
    ///   - isAtBottom: Whether the viewport follows the newest output.
    /// - Returns: The current entry index, or `nil` when no anchored prompt
    ///   starts at or above the reading line.
    public func currentIndex(viewportTop: Int, viewportRows: Int, isAtBottom: Bool = false) -> Int? {
        let line = isAtBottom ? viewportTop + max(0, viewportRows - 1) : viewportTop + 1
        return lastAnchoredIndex { $0 <= line }
    }

    /// Where "previous turn" goes: the nearest prompt above the reading line.
    /// At the live bottom, the newest prompt on screen comes first.
    public func previousTarget(viewportTop: Int, viewportRows: Int, isAtBottom: Bool = false) -> Int? {
        if isAtBottom,
           let newest = currentIndex(viewportTop: viewportTop, viewportRows: viewportRows, isAtBottom: true),
           let row = anchorRows[newest], row > viewportTop + 1 {
            return newest
        }
        return lastAnchoredIndex { $0 < viewportTop + 1 }
    }

    /// Where "next turn" goes: the nearest prompt below the reading line, or
    /// `nil` when none is.
    public func nextTarget(viewportTop: Int, viewportRows: Int, isAtBottom: Bool = false) -> Int? {
        if isAtBottom { return nil }
        return anchorRows.indices.first { index in
            guard let row = anchorRows[index] else { return false }
            return row > viewportTop + 1
        }
    }

    private func lastAnchoredIndex(where predicate: (Int) -> Bool) -> Int? {
        var result: Int?
        for (index, row) in anchorRows.enumerated() {
            guard let row else { continue }
            if predicate(row) { result = index } else { break }
        }
        return result
    }
}
