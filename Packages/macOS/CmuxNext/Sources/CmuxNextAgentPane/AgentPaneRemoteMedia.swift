import Foundation

/// A video of a chat on another machine, played in place (Leo, 2026-11-04: "i can neither preview
/// a vid in place nor have it pop up anymore :("). Its bytes stay on that machine: each range the
/// player asks for is read there, through the chat's own daemon attachment
/// (`agent-session-media` with an `offset`, cmux-tui agent_session_media.rs) and that machine's
/// acpmux media reader, which checks the path as it does a remote chat's image (the chat's folder,
/// `/tmp`, its home or its uploads; no link, no dot name, no key file; a sniffed mp4, mov, m4v or
/// webm of at most 200 MiB). Nothing of this Mac's disk is read for it.
///
/// This only passes bytes through: one open file on that machine (its `handle`) serves the ranges
/// in turn, reopened when acpmux closed it (at its end, after 2 idle minutes); a file whose
/// `identity` changed since the first read is refused, never mixed with what was played.
actor AgentPaneRemoteMedia {
    /// `path, offset, length, handle`: the daemon's answer `{offset, size, identity, data,
    /// mimeType?, handle?}` (``AgentPaneTransport/remoteMediaRange``).
    typealias Read = @Sendable (String, Int, Int, String?) async throws -> Data

    /// The most bytes one read asks for: acpmux's own range cap.
    nonisolated static let maximumRange = 6 << 20
    /// The first read: enough for a player's first probe and a movie's header.
    nonisolated static let headBytes = 256 << 10
    /// The extension each type acpmux sniffs is served under (``AgentPaneMediaGrants/types``).
    nonisolated static let extensions = ["video/mp4": "mp4", "video/quicktime": "mov", "video/x-m4v": "m4v", "video/webm": "webm"]

    nonisolated let path: String
    nonisolated let size: Int
    /// The extension its bytes really are, by acpmux's sniff.
    nonisolated let ext: String
    private let identity: String
    private let read: Read
    private var handle: String?
    /// The first bytes, read at the open, served again without a round trip.
    private let head: Data
    /// The read running now: ranges go one at a time, so one open file serves them all.
    private var last: Task<Void, Never>?

    private init(path: String, size: Int, ext: String, identity: String, read: @escaping Read, handle: String?, head: Data) {
        self.path = path
        self.size = size
        self.ext = ext
        self.identity = identity
        self.read = read
        self.handle = handle
        self.head = head
    }

    /// One answer of the daemon, checked.
    nonisolated struct Chunk: Equatable, Sendable {
        var offset: Int
        var size: Int
        var identity: String
        var data: Data
        var mimeType: String?
        var handle: String?
    }

    nonisolated static func chunk(_ json: Data) -> Chunk? {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let offset = object["offset"] as? Int, let size = object["size"] as? Int, size > 0,
              let identity = object["identity"] as? String, !identity.isEmpty,
              let encoded = object["data"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty,
              offset >= 0, offset < size, data.count <= size - offset else { return nil }
        return Chunk(offset: offset, size: size, identity: identity, data: data,
                     mimeType: object["mimeType"] as? String, handle: object["handle"] as? String)
    }

    /// Opens the video `path` names on that machine with its first bytes; nil when that machine
    /// refuses it (not a video, outside the chat's folders, too large, an older daemon).
    nonisolated static func open(_ path: String, read: @escaping Read) async -> AgentPaneRemoteMedia? {
        guard let json = try? await read(path, 0, headBytes, nil), let first = chunk(json), first.offset == 0,
              let mime = first.mimeType, let ext = extensions[mime] else { return nil }
        return AgentPaneRemoteMedia(path: path, size: first.size, ext: ext, identity: first.identity, read: read,
                                    handle: first.handle, head: first.data)
    }

    /// At most `length` bytes from `offset` (inside the file), read on that machine; nil when it
    /// refuses or the file changed since it was opened.
    func bytes(at offset: Int, length: Int) async -> Data? {
        guard offset >= 0, offset < size, length > 0 else { return nil }
        let want = min(length, size - offset, Self.maximumRange)
        if offset + want <= head.count { return head.subdata(in: offset ..< offset + want) }
        let previous = last
        let task = Task<Data?, Never> {
            await previous?.value
            return await self.readNow(at: offset, length: want)
        }
        last = Task { _ = await task.value }
        return await task.value
    }

    /// One range: on the open file, else (acpmux closed it) on a new open of the same file.
    private func readNow(at offset: Int, length: Int) async -> Data? {
        if let open = handle, let data = await range(at: offset, length: length, handle: open) { return data }
        handle = nil
        return await range(at: offset, length: length, handle: nil)
    }

    private func range(at offset: Int, length: Int, handle open: String?) async -> Data? {
        guard let json = try? await read(path, offset, length, open), let chunk = Self.chunk(json),
              chunk.offset == offset, chunk.size == size, chunk.identity == identity, chunk.data.count <= length,
              open != nil || chunk.mimeType.flatMap({ Self.extensions[$0] }) == ext else { return nil }
        handle = chunk.handle
        return chunk.data
    }
}
