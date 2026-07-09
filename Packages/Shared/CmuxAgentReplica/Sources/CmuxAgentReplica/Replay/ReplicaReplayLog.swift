public import Foundation

/// Encodes and decodes newline-delimited replay records.
public struct ReplicaReplayLog: Codable, Hashable, Sendable {
    /// Decoded replay records.
    public let records: [ReplicaReplayRecord]
    /// Count of lines skipped during decoding.
    public let skippedLineCount: Int

    /// Creates a replay log value.
    /// - Parameters:
    ///   - records: Decoded replay records.
    ///   - skippedLineCount: Count of skipped lines.
    public init(records: [ReplicaReplayRecord], skippedLineCount: Int = 0) {
        self.records = records
        self.skippedLineCount = skippedLineCount
    }

    /// Encodes records as JSONL data.
    /// - Returns: UTF-8 JSONL data.
    public func encodeJSONL() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()
        for record in records {
            output.append(try encoder.encode(record))
            output.append(0x0A)
        }
        return output
    }

    /// Decodes JSONL data, skipping invalid lines.
    /// - Parameter data: UTF-8 JSONL data.
    /// - Returns: A replay log with decoded records and a skipped-line count.
    public static func decodeJSONL(_ data: Data) -> ReplicaReplayLog {
        let decoder = JSONDecoder()
        let text = String(decoding: data, as: UTF8.self)
        var records: [ReplicaReplayRecord] = []
        var skipped = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard !line.isEmpty, let lineData = String(line).data(using: .utf8) else {
                continue
            }
            do {
                records.append(try decoder.decode(ReplicaReplayRecord.self, from: lineData))
            } catch {
                skipped += 1
            }
        }
        return ReplicaReplayLog(records: records, skippedLineCount: skipped)
    }
}
