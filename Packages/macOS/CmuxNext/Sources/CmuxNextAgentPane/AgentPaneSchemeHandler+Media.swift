import Foundation
import WebKit

extension AgentPaneSchemeHandler {
    /// Bytes one media response carries at most; the player asks for the next range.
    nonisolated static let mediaChunk = 8 << 20

    /// One answer to a media request: 200 for the whole file, 206 for a range, 416 past the end.
    nonisolated struct MediaSlice: Sendable {
        var status: Int
        var headers: [String: String]
        var data: Data
    }

    /// The granted file a `cmux-agent://pane/__media/` URL names (``AgentPaneMediaGrants``).
    static func mediaFile(for url: URL) -> URL? {
        AgentPaneMediaGrants.shared.file(for: url)
    }

    /// The part of `file` an HTTP `Range` header asks for (`bytes=a-b`, `bytes=a-` or `bytes=-n`),
    /// at most ``mediaChunk`` bytes. Nil when the file cannot be read or is no longer the regular
    /// file that was granted (a link swapped in after the grant).
    nonisolated static func mediaSlice(of file: URL, range: String?) -> MediaSlice? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize
        else { return nil }
        var headers = [
            "Content-Type": AgentPaneMediaGrants.types[file.pathExtension.lowercased()] ?? "application/octet-stream",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": resourcePolicy,
        ]
        var lower = 0, upper = size - 1
        if let range {
            guard let (start, end) = byteRange(range, size: size), start < size else {
                headers["Content-Range"] = "bytes */\(size)"
                headers["Content-Length"] = "0"
                return MediaSlice(status: 416, headers: headers, data: Data())
            }
            lower = start
            upper = min(end, size - 1)
        }
        upper = min(upper, lower + mediaChunk - 1)
        let partial = range != nil || upper < size - 1
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(lower))) != nil,
              let data = size == 0 ? Data() : try? handle.read(upToCount: upper - lower + 1) else { return nil }
        headers["Content-Length"] = String(data.count)
        if partial { headers["Content-Range"] = "bytes \(lower)-\(lower + data.count - 1)/\(size)" }
        return MediaSlice(status: partial ? 206 : 200, headers: headers, data: data)
    }

    /// The first and last byte a `Range` header names, nil for a header this does not read.
    nonisolated static func byteRange(_ header: String, size: Int) -> (Int, Int)? {
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes="), !spec.contains(",") else { return nil }
        let parts = spec.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let first = parts[0].trimmingCharacters(in: .whitespaces), last = parts[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let count = Int(last), count > 0 else { return nil }
            return (max(0, size - count), size - 1)
        }
        guard let start = Int(first), start >= 0 else { return nil }
        if last.isEmpty { return (start, size - 1) }
        guard let end = Int(last), end >= start else { return nil }
        return (start, end)
    }

    /// Reads the slice off the main thread.
    @concurrent nonisolated static func readSlice(of file: URL, range: String?) async -> MediaSlice? {
        // concurrency-allow: @concurrent, so this read never runs on the main actor
        mediaSlice(of: file, range: range)
    }

    /// Answers `task` for the granted `file`; a stopped task is never answered.
    func serveMedia(_ file: URL, url: URL, task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        let range = task.request.value(forHTTPHeaderField: "Range")
        // task-owner: one range read per media request; a stopped task is never answered
        Task { @MainActor [weak self] in
            let slice = await Self.readSlice(of: file, range: range)
            guard let self, self.active.remove(id) != nil else { return }
            guard let slice,
                  let response = HTTPURLResponse(url: url, statusCode: slice.status, httpVersion: "HTTP/1.1", headerFields: slice.headers)
            else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(response)
            task.didReceive(slice.data)
            task.didFinish()
        }
    }
}
