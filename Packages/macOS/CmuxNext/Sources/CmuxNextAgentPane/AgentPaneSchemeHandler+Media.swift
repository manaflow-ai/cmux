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

    /// What a granted media URL plays: a file on this Mac, or a video of a chat on another
    /// machine, read there in ranges (``AgentPaneRemoteMedia``).
    enum MediaSource {
        case file(URL)
        case remote(AgentPaneRemoteMedia)
    }

    /// The granted file a `cmux-agent://pane/__media/` URL names (``AgentPaneMediaGrants``).
    static func mediaFile(for url: URL) -> URL? {
        AgentPaneMediaGrants.shared.file(for: url)
    }

    /// The granted file or remote video a media URL names; nil for a token never granted.
    static func mediaSource(for url: URL) -> MediaSource? {
        if let file = mediaFile(for: url) { return .file(file) }
        return AgentPaneMediaGrants.shared.remote(for: url).map(MediaSource.remote)
    }

    /// The slice of `source` a `Range` header asks for, read off the main actor.
    static func readSlice(of source: MediaSource, range: String?) async -> MediaSlice? {
        switch source {
        case .file(let file): await readSlice(of: file, range: range)
        case .remote(let media): await remoteSlice(of: media, range: range)
        }
    }

    /// The headers every media answer carries, for a file served as `ext`.
    nonisolated static func mediaHeaders(ext: String) -> [String: String] {
        [
            "Content-Type": AgentPaneMediaGrants.types[ext.lowercased()] ?? "application/octet-stream",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": resourcePolicy,
        ]
    }

    /// The bytes a `Range` header asks of a file of `size`, at most ``mediaChunk``: `(lower, upper,
    /// partial)`, or nil past the end (a 416).
    nonisolated static func sliceBounds(size: Int, range: String?) -> (lower: Int, upper: Int, partial: Bool)? {
        var lower = 0, upper = size - 1
        if let range {
            guard let (start, end) = byteRange(range, size: size), start < size else { return nil }
            lower = start
            upper = min(end, size - 1)
        }
        upper = min(upper, lower + mediaChunk - 1)
        return (lower, upper, range != nil || upper < size - 1)
    }

    /// The 416 answer for a range past the end of a file of `size`.
    nonisolated static func unsatisfiable(_ headers: [String: String], size: Int) -> MediaSlice {
        var headers = headers
        headers["Content-Range"] = "bytes */\(size)"
        headers["Content-Length"] = "0"
        return MediaSlice(status: 416, headers: headers, data: Data())
    }

    /// The slice of a remote chat's video a `Range` header asks for, read on that machine (each
    /// read at most ``AgentPaneRemoteMedia/maximumRange``: the player asks for the rest).
    static func remoteSlice(of media: AgentPaneRemoteMedia, range: String?) async -> MediaSlice? {
        var headers = mediaHeaders(ext: media.ext)
        guard let bounds = sliceBounds(size: media.size, range: range) else { return unsatisfiable(headers, size: media.size) }
        guard let data = await media.bytes(at: bounds.lower, length: bounds.upper - bounds.lower + 1) else { return nil }
        let partial = bounds.partial || data.count < media.size
        headers["Content-Length"] = String(data.count)
        if partial { headers["Content-Range"] = "bytes \(bounds.lower)-\(bounds.lower + data.count - 1)/\(media.size)" }
        return MediaSlice(status: partial ? 206 : 200, headers: headers, data: data)
    }

    /// The part of `file` an HTTP `Range` header asks for (`bytes=a-b`, `bytes=a-` or `bytes=-n`),
    /// at most ``mediaChunk`` bytes. Nil when the file cannot be read or is no longer the regular
    /// file that was granted (a link swapped in after the grant).
    nonisolated static func mediaSlice(of file: URL, range: String?) -> MediaSlice? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize
        else { return nil }
        var headers = mediaHeaders(ext: file.pathExtension)
        guard let (lower, upper, partial) = sliceBounds(size: size, range: range) else { return unsatisfiable(headers, size: size) }
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

    /// Answers `task` for the granted `source`; a stopped task is never answered.
    func serveMedia(_ source: MediaSource, url: URL, task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        active.insert(id)
        let range = task.request.value(forHTTPHeaderField: "Range")
        // task-owner: one range read per media request; a stopped task is never answered
        Task { @MainActor [weak self] in
            let slice = await Self.readSlice(of: source, range: range)
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
