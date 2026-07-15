import Foundation

/// A bounded terminal-history window around the visible viewport.
public struct MobileTerminalScrollPrefetchWindow: Equatable, Sendable {
    /// Rows fetched in the active scroll direction.
    public static let largeWindowRows = 600

    /// Rows retained on the opposite side for immediate direction reversals.
    public static let oppositeDirectionGuardRows = 120

    /// Local scroll distance that triggers another remote prefetch.
    public static let refreshDistanceRows = 120.0

    /// Older rows requested before the viewport.
    public let rowsBeforeViewport: Int

    /// Newer rows requested after the viewport.
    public let rowsAfterViewport: Int

    /// Creates a nonnegative prefetch window.
    ///
    /// - Parameters:
    ///   - rowsBeforeViewport: Older rows requested before the viewport.
    ///   - rowsAfterViewport: Newer rows requested after the viewport.
    public init(rowsBeforeViewport: Int, rowsAfterViewport: Int) {
        self.rowsBeforeViewport = max(0, rowsBeforeViewport)
        self.rowsAfterViewport = max(0, rowsAfterViewport)
    }

    /// Creates the standard directional window for a scroll delta.
    ///
    /// - Parameter lines: Positive values scroll toward older rows; negative
    ///   values scroll toward newer rows.
    /// - Returns: A 600-row directional window with a 120-row reversal guard.
    public static func directional(for lines: Double) -> Self {
        if lines >= 0 {
            return Self(
                rowsBeforeViewport: largeWindowRows,
                rowsAfterViewport: oppositeDirectionGuardRows
            )
        }
        return Self(
            rowsBeforeViewport: oppositeDirectionGuardRows,
            rowsAfterViewport: largeWindowRows
        )
    }

    /// Enforces the shared directional and opposite-side row budgets.
    ///
    /// The requested window orientation is authoritative when its sides differ,
    /// preserving settlement and legacy one-sided requests. Equal requests use
    /// the latest scroll direction, or default toward older history.
    ///
    /// - Parameters:
    ///   - requestedBeforeRows: Requested older-row count.
    ///   - requestedAfterRows: Requested newer-row count.
    ///   - directionLines: Latest nonzero scroll delta when available.
    /// - Returns: A window capped to 600 rows in one direction and 120 in the
    ///   opposite direction.
    public static func bounded(
        requestedBeforeRows: Int,
        requestedAfterRows: Int,
        directionLines: Double?
    ) -> Self {
        let requestedBefore = max(0, requestedBeforeRows)
        let requestedAfter = max(0, requestedAfterRows)
        let prefersBefore: Bool
        if requestedBefore != requestedAfter {
            prefersBefore = requestedBefore > requestedAfter
        } else if let directionLines,
                  directionLines.isFinite,
                  directionLines != 0 {
            prefersBefore = directionLines > 0
        } else {
            prefersBefore = true
        }

        return Self(
            rowsBeforeViewport: min(
                requestedBefore,
                prefersBefore ? largeWindowRows : oppositeDirectionGuardRows
            ),
            rowsAfterViewport: min(
                requestedAfter,
                prefersBefore ? oppositeDirectionGuardRows : largeWindowRows
            )
        )
    }
}
