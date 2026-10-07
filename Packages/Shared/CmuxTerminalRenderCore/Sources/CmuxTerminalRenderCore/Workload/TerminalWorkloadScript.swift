public import Foundation

/// A workload ready to replay: the grid it was written for and its output
/// split into the chunks the fixture source delivers, one per frame.
public struct TerminalWorkloadScript: Hashable, Sendable {
    public var name: String
    public var cols: Int
    public var rows: Int
    public var chunks: [Data]

    public init(name: String, cols: Int, rows: Int, chunks: [Data]) {
        self.name = name
        self.cols = cols
        self.rows = rows
        self.chunks = chunks
    }

    public var totalBytes: Int { chunks.reduce(0) { $0 + $1.count } }
}
