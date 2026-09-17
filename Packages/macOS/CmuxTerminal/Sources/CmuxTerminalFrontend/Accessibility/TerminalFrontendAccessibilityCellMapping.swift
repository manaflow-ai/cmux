internal import Foundation

struct TerminalFrontendAccessibilityCellMapping: Equatable {
    let row: UInt64
    let column: Int
    let columnSpan: Int
    let range: NSRange
}
