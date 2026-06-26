public import Foundation

extension URL {
    /// Streams JSON-lines from the start of this file URL, decoding each
    /// newline-delimited record as a `[String: Any]` and handing it to `body`.
    ///
    /// `body` returns `true` to stop early. Reads in 64 KiB chunks and caps the
    /// total bytes read at `maxBytes`. A trailing line without a final newline is
    /// flushed at EOF. Records that fail to open, read, or JSON-decode are
    /// skipped silently, matching the original best-effort streaming behavior.
    public func forEachJSONLine(
        maxBytes: Int,
        body: ([String: Any]) -> Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return }
        defer { try? handle.close() }
        var leftover = Data()
        var totalRead = 0
        let chunkSize = 64 * 1024
        while totalRead < maxBytes {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            if chunk.isEmpty { break }
            totalRead += chunk.count
            leftover.append(chunk)
            while let nl = leftover.firstIndex(of: 0x0a) {
                let lineData = leftover.subdata(in: 0..<nl)
                leftover.removeSubrange(0..<(nl + 1))
                if lineData.isEmpty { continue }
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    if body(obj) { return }
                }
            }
        }
        // Flush trailing line if no newline at EOF.
        if !leftover.isEmpty,
           let obj = try? JSONSerialization.jsonObject(with: leftover) as? [String: Any] {
            _ = body(obj)
        }
    }
}
