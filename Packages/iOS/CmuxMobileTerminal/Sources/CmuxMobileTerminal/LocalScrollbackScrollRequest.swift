#if canImport(UIKit)
struct LocalScrollbackScrollRequest: Equatable, Sendable {
    var lines: Double
    var col: Int
    var row: Int

    mutating func append(_ request: LocalScrollbackScrollRequest) {
        lines += request.lines
        col = request.col
        row = request.row
    }
}
#endif
