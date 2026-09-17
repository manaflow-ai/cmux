import Foundation

struct SimulatorProcessOutputBatcher {
    private static let newline: UInt8 = 10
    private static let maximumPendingBytes = 64 * 1_024
    private static let maximumLinesPerBatch = 32

    private var pending = Data()
    private var lines: [String] = []

    mutating func append(_ data: Data) -> [[String]] {
        pending.append(data)
        if pending.count > Self.maximumPendingBytes,
           !pending.contains(Self.newline) {
            pending = Data(pending.suffix(Self.maximumPendingBytes))
        }

        var batches: [[String]] = []
        var lineStart = pending.startIndex
        while let newlineIndex = pending[lineStart...].firstIndex(of: Self.newline) {
            let lineData = pending[lineStart..<newlineIndex]
            lines.append(String(decoding: lineData, as: UTF8.self) + "\n")
            lineStart = pending.index(after: newlineIndex)
            if lines.count == Self.maximumLinesPerBatch {
                batches.append(lines)
                lines.removeAll(keepingCapacity: true)
            }
        }
        if lineStart != pending.startIndex {
            pending.removeSubrange(pending.startIndex..<lineStart)
        }
        if !lines.isEmpty {
            batches.append(lines)
            lines.removeAll(keepingCapacity: true)
        }
        return batches
    }

    mutating func finish() -> [String]? {
        if !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        guard !lines.isEmpty else { return nil }
        defer { lines.removeAll(keepingCapacity: true) }
        return lines
    }
}
