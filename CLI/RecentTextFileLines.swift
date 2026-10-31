import Foundation

/// The last lines of a text file, as hooks read a transcript's tail. The CLI
/// reads through `CMUXCLI.readRecentTextFileLines`; the test target compiles
/// this file directly.
enum RecentTextFileLines {
    /// The lines of the last `maxBytes` of the file at `path`, widened (up to
    /// 8 times `maxBytes`) until the window holds a whole line, without the
    /// partial line the window starts in. `nil` when the file cannot be read,
    /// is empty, or is not UTF-8.
    ///
    /// With `endingAt`, the window ends at that byte offset instead of the
    /// file's end: for an append-only file such as a Claude transcript, exactly
    /// what it held when its size was `endingAt`. A file now shorter than that
    /// was truncated or replaced, and gives `nil`. A record is whole only with
    /// its newline: the bytes after the window's last newline, a record cut
    /// mid-write (maybe inside a multi-byte character), are left out.
    static func read(path: String, maxBytes: UInt64, endingAt end: UInt64? = nil) -> [String]? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        defer { try? handle.close() }

        func isASCIIWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
        }

        func hasCompleteLineAfterLeadingBoundary(_ data: Data, readStart: UInt64) -> Bool {
            guard readStart > 0 else { return true }
            guard let newline = data.firstIndex(of: 0x0A) else { return false }
            return data[data.index(after: newline)...].contains { !isASCIIWhitespace($0) }
        }

        func completeRecords(_ data: Data) -> Data {
            guard end != nil else { return data }
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return Data() }
            return Data(data[...lastNewline])
        }

        func readWindow(from start: UInt64, to stop: UInt64) throws -> Data? {
            try handle.seek(toOffset: start)
            guard end != nil else { return try handle.readToEnd() }
            return try handle.read(upToCount: Int(stop - start))
        }

        let size: UInt64
        do {
            let fileSize = try handle.seekToEnd()
            if let end, end > fileSize { return nil }
            size = end ?? fileSize
            var readStart = size > maxBytes ? size - maxBytes : 0
            guard var data = try readWindow(from: readStart, to: size), !data.isEmpty else {
                return nil
            }
            let maxWindowBytes = maxBytes > UInt64.max / 8 ? UInt64.max : maxBytes * 8

            while !hasCompleteLineAfterLeadingBoundary(completeRecords(data), readStart: readStart), readStart > 0 {
                let currentWindowBytes = size - readStart
                guard currentWindowBytes < maxWindowBytes else { break }
                let remainingWindowBytes = maxWindowBytes - currentWindowBytes
                let expansionBytes = min(readStart, maxBytes, remainingWindowBytes)
                guard expansionBytes > 0 else { break }

                readStart -= expansionBytes
                guard let expandedData = try readWindow(from: readStart, to: size), !expandedData.isEmpty else {
                    return nil
                }
                data = expandedData
            }

            data = completeRecords(data)
            if readStart > 0, let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...newline)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text.components(separatedBy: "\n")
        } catch {
            return nil
        }
    }

    /// The byte size of the file ``read(path:maxBytes:endingAt:)`` reads at
    /// `path`, following a symlink as it does, from `stat(2)` without reading
    /// the content; `nil` when it cannot be read.
    static func byteSize(path: String) -> UInt64? {
        var info = stat()
        guard stat(NSString(string: path).expandingTildeInPath, &info) == 0 else { return nil }
        return UInt64(exactly: info.st_size)
    }
}
