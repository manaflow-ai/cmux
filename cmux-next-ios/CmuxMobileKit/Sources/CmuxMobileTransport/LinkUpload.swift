import Foundation

/// Sends a file to the Mac over the link's `upload` service (PROTOCOL.md):
/// one channel per file, opened with `{name, size, cwd?}`, the bytes as data
/// frames, then the Mac's one reply `{"path","size"}` or `{"error","message"}`.
/// The Mac writes a new file (never replacing one) in
/// `<cwd>/.cmux/attachments/phone-<session>/` when `cwd` is a folder of one
/// of its tabs, else in its own uploads folder, and answers its real path.
public enum LinkUpload {
    /// Bytes per channel write: the link splits larger writes anyway.
    static let chunkBytes = 192 << 10

    public struct Failure: Error, Equatable, Sendable, LocalizedError {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    /// What an upload sends: bytes held in memory (a pasted or camera image),
    /// or a file on the phone, read `chunkBytes` at a time so a file of any
    /// size never sits whole in memory. There is no size cap.
    public enum Payload: Sendable, Equatable {
        case data(Data)
        case file(URL)
    }

    /// Uploads `data` as `name` and returns the file's absolute path on the Mac.
    public static func upload(_ data: Data, name: String, cwd: String?, over link: any MacLink) async throws -> String {
        try await upload(.data(data), name: name, cwd: cwd, over: link)
    }

    /// Streams the file at `url` as `name` and returns its absolute path on the Mac.
    public static func upload(fileAt url: URL, name: String, cwd: String?, over link: any MacLink) async throws -> String {
        try await upload(.file(url), name: name, cwd: cwd, over: link)
    }

    /// Uploads `payload` as `name` and returns the file's absolute path on the Mac.
    /// Nonisolated async: the file reads run off the caller's actor.
    public static func upload(_ payload: Payload, name: String, cwd: String?, over link: any MacLink,
                              scope: any SecurityScope = SystemSecurityScope()) async throws -> String {
        switch payload {
        case .data(let data):
            return try await send(name: name, size: data.count, cwd: cwd, over: link) { offset, count in
                data.subdata(in: data.startIndex + offset..<data.startIndex + offset + count)
            }
        case .file(let url):
            // A Files pick is security-scoped: its access stays open for the whole
            // stream and closes when the upload ends, however it ends.
            let access = ScopedFile(url, scope: scope).open()
            defer { access.close() }
            let handle: FileHandle
            let size: Int
            do {
                handle = try FileHandle(forReadingFrom: url)
                size = Int(try handle.seekToEnd())
                try handle.seek(toOffset: 0)
            } catch {
                throw unreadable(name)
            }
            defer { try? handle.close() }
            return try await send(name: name, size: size, cwd: cwd, over: link) { _, count in
                try handle.read(upToCount: count) ?? Data()
            }
        }
    }

    static func unreadable(_ name: String) -> Failure {
        Failure(code: "unreadable", message: "Couldn't read \(name) on this iPhone.")
    }

    /// Opens the channel with `size`, sends `nextChunk(offset, count)` until
    /// `size` bytes went, then reads the Mac's one reply.
    private static func send(name: String, size: Int, cwd: String?, over link: any MacLink,
                             nextChunk: (_ offset: Int, _ count: Int) throws -> Data) async throws -> String {
        var args = ["name": name, "size": String(size)]
        if let cwd, cwd.hasPrefix("/") { args["cwd"] = cwd }
        let channel: any LinkChannel
        do {
            channel = try await link.openChannel(service: "upload", args: args)
        } catch let error as LinkError {
            throw Failure(code: error.code, message: error.message)
        }
        // Cancelling the upload closes its channel, which ends a wait for the
        // Mac's reply; the stream stops at its next chunk. The caller's file
        // handle and scope then close as the upload returns.
        return try await withTaskCancellationHandler {
            // The Mac may refuse before reading (a folder it won't write to): a
            // failed send is not the answer, the reply is.
            var offset = 0
            while offset < size {
                if Task.isCancelled {
                    await channel.close(code: "cancelled", reason: "cancelled")
                    throw CancellationError()
                }
                let chunk = (try? nextChunk(offset, min(chunkBytes, size - offset))) ?? Data()
                // The file shrank or stopped reading: cancel rather than hand the Mac a short file.
                guard !chunk.isEmpty else {
                    await channel.close(code: "cancelled", reason: "unreadable")
                    throw unreadable(name)
                }
                do { try await channel.send(chunk) } catch { break }
                offset += chunk.count
            }
            var reply = Data()
            while let chunk = try await channel.receive() {
                reply.append(chunk)
            }
            try Task.checkCancellation()
            return try path(fromReply: reply)
        } onCancel: {
            Task { await channel.close(code: "cancelled", reason: "cancelled") }
        }
    }

    /// The path in the Mac's reply, or its refusal.
    public static func path(fromReply reply: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            throw Failure(code: "closed", message: "The Mac closed the upload without an answer.")
        }
        if let path = object["path"] as? String, path.hasPrefix("/") { return path }
        throw Failure(code: object["error"] as? String ?? "failed", message: object["message"] as? String ?? "The upload failed.")
    }

    /// `<cwd>` with a trailing slash removed, or nil.
    public static func folder(_ cwd: String?) -> String? {
        guard var cwd, cwd.hasPrefix("/") else { return nil }
        while cwd.count > 1, cwd.hasSuffix("/") { cwd.removeLast() }
        return cwd
    }
}
