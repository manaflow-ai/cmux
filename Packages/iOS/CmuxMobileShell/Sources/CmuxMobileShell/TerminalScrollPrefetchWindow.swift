import Foundation

struct TerminalScrollPrefetchWindow: Equatable, Sendable {
    static let largeWindowRows = 600
    static let oppositeDirectionGuardRows = 120
    static let refreshDistanceRows = 120.0

    let rowsBeforeViewport: Int
    let rowsAfterViewport: Int

    static func directional(for lines: Double) -> Self {
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
}
