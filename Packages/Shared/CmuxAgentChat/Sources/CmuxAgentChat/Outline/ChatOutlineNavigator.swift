import Foundation

/// Answers "which turn is on screen" and "where does next/previous go" from
/// resolved prompt rows and the terminal viewport.
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

    /// The entry whose exchange occupies the viewport: the last anchored
    /// prompt at or above the viewport's upper third.
    ///
    /// - Parameters:
    ///   - viewportTop: Absolute row at the top of the viewport.
    ///   - viewportRows: Visible row count.
    /// - Returns: The current entry index, or `nil` when no anchored prompt
    ///   starts at or above the probe row.
    public func currentIndex(viewportTop: Int, viewportRows: Int) -> Int? {
        let probe = viewportTop + max(0, viewportRows / 3)
        var current: Int?
        for (index, row) in anchorRows.enumerated() {
            guard let row else { continue }
            if row <= probe {
                current = index
            } else {
                break
            }
        }
        return current
    }

    /// Where "previous turn" goes: the start of the current turn when its
    /// prompt has scrolled above the viewport, otherwise the prompt before it.
    ///
    /// - Parameters:
    ///   - viewportTop: Absolute row at the top of the viewport.
    ///   - viewportRows: Visible row count.
    public func previousTarget(viewportTop: Int, viewportRows: Int) -> Int? {
        let current = currentIndex(viewportTop: viewportTop, viewportRows: viewportRows)
        if let current, let row = anchorRows[current], row < viewportTop {
            return current
        }
        guard let current else { return nil }
        return previousAnchoredIndex(before: current)
    }

    /// Where "next turn" goes: the next anchored prompt below the current
    /// turn, or `nil` when the current turn is the last one.
    ///
    /// - Parameters:
    ///   - viewportTop: Absolute row at the top of the viewport.
    ///   - viewportRows: Visible row count.
    public func nextTarget(viewportTop: Int, viewportRows: Int) -> Int? {
        nextAnchoredIndex(after: currentIndex(viewportTop: viewportTop, viewportRows: viewportRows))
    }

    /// The nearest anchored entry after `index`, or `nil` at the end.
    ///
    /// - Parameter index: The current entry, or `nil` when none is current
    ///   (the viewport is above every anchored prompt).
    public func nextAnchoredIndex(after index: Int?) -> Int? {
        let start = (index ?? -1) + 1
        guard start < anchorRows.count else { return nil }
        return (start..<anchorRows.count).first { anchorRows[$0] != nil }
    }

    /// The nearest anchored entry before `index`.
    ///
    /// - Parameter index: The current entry, or `nil` to start from the end
    ///   of the outline.
    public func previousAnchoredIndex(before index: Int?) -> Int? {
        let end = index ?? anchorRows.count
        guard end > 0 else { return nil }
        return (0..<min(end, anchorRows.count)).reversed().first { anchorRows[$0] != nil }
    }
}
