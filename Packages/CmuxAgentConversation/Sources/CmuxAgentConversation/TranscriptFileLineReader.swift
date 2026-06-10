import Foundation

/// A chunked, size-capped reader that splits a `.jsonl` transcript into lines.
///
/// This is the bounded-read primitive shared by the file-backed conversation
/// sources: it never reads more than ``TranscriptFileLineReader/maxBytes`` of
/// the file and skips any single line longer than the oversized-line guard, so
/// one runaway transcript (or one pathological embedded blob) cannot stall the
/// UI or blow up memory.
struct TranscriptFileLineReader: Sendable {
    /// The maximum number of bytes read from the file.
    let maxBytes: Int

    /// A single line longer than this is skipped entirely.
    let maxLineBytes: Int

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - maxBytes: The total read cap. Defaults to 32 MiB, generous enough
    ///     for any realistic agent session.
    ///   - maxLineBytes: The oversized-line guard. Defaults to 8 MiB.
    init(maxBytes: Int = 32 * 1024 * 1024, maxLineBytes: Int = 8 * 1024 * 1024) {
        self.maxBytes = maxBytes
        self.maxLineBytes = maxLineBytes
    }

    /// Reads the file at `url` into UTF-8 lines.
    ///
    /// - Parameter url: The transcript file to read.
    /// - Returns: The decoded lines, or `[]` when the file cannot be opened.
    func readLines(url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var lines: [String] = []
        var leftover = Data()
        var totalRead = 0
        let chunkSize = 64 * 1024

        while totalRead < maxBytes {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            totalRead += chunk.count
            leftover.append(chunk)
            while let newline = leftover.firstIndex(of: 0x0a) {
                let lineData = leftover.subdata(in: leftover.startIndex..<newline)
                leftover.removeSubrange(leftover.startIndex...newline)
                if lineData.isEmpty || lineData.count > maxLineBytes { continue }
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
            }
        }
        if !leftover.isEmpty, leftover.count <= maxLineBytes,
           let line = String(data: leftover, encoding: .utf8) {
            lines.append(line)
        }
        return lines
    }
}
