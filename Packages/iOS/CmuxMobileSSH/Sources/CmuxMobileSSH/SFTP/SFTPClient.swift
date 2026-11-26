import Foundation

/// SFTP v3 client (draft-ietf-secsh-filexfer-02, what OpenSSH `sftp-server`
/// speaks) over an `sftp` subsystem channel.
///
/// Requests are multiplexed by id: a background task frames packets off the
/// channel and resolves each request's slot, so transfers keep several reads
/// or writes in flight. Once the channel closes every pending and future
/// request fails with ``SFTPError/connectionLost``.
public actor SFTPClient {
    /// Bytes per READ/WRITE request. OpenSSH's own client default.
    static let chunkSize = 32 * 1024
    /// Requests kept in flight during a transfer.
    static let window = 16

    private enum Slot {
        case waiting
        case awaiting(CheckedContinuation<SFTPResponse, any Error>)
        case done(Result<SFTPResponse, any Error>)
        /// The caller gave up on this reply; drop it on arrival.
        case discarded
    }

    private let session: SSHSessionChannel
    private var framer = SFTPFramer()
    private var slots: [UInt32: Slot] = [:]
    private var nextID: UInt32 = 0
    private var version: CheckedContinuation<UInt32, any Error>?
    private var lost = false
    private var reader: Task<Void, Never>?

    private init(session: SSHSessionChannel) {
        self.session = session
    }

    /// Opens the `sftp` subsystem on `connection` and completes the version handshake.
    public static func open(on connection: SSHConnection) async throws -> SFTPClient {
        let session = try await connection.openSession(start: .subsystem("sftp"))
        let client = SFTPClient(session: session)
        do {
            try await client.handshake()
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    /// The protocol version the server agreed to.
    public private(set) var serverVersion: UInt32 = 0

    private func handshake() async throws {
        startReader()
        var body = SFTPWriter()
        body.uint32(3)
        let packet = body.packet(type: .initialize)
        // Register for VERSION before writing so a fast reply is never missed.
        let versionReply: UInt32 = try await withCheckedThrowingContinuation { continuation in
            version = continuation
            Task { await self.writeHandshake(packet) }
        }
        guard versionReply >= 3 else { throw SFTPError.unexpectedPacket("version \(versionReply)") }
        serverVersion = versionReply
    }

    private func writeHandshake(_ packet: Data) async {
        do {
            try await session.write(packet)
        } catch {
            connectionLost()
        }
    }

    /// Closes the channel. Pending requests fail with ``SFTPError/connectionLost``.
    public func close() async {
        connectionLost()
        reader?.cancel()
        await session.close()
    }

    // MARK: - Paths and metadata

    /// Canonicalizes `path` on the server (`"."` resolves to the login directory).
    public func realpath(_ path: String) async throws -> String {
        guard case .name(let entries) = try await call(.realpath, { $0.string(path) }), let first = entries.first else {
            throw SFTPError.unexpectedPacket("realpath reply")
        }
        return first.name
    }

    /// Attributes of `path`, following symlinks.
    public func stat(_ path: String) async throws -> SFTPAttributes {
        try attributes(try await call(.stat, { $0.string(path) }))
    }

    /// Attributes of `path` itself, not its symlink target.
    public func lstat(_ path: String) async throws -> SFTPAttributes {
        try attributes(try await call(.lstat, { $0.string(path) }))
    }

    /// Lists `path`, excluding `.` and `..`, in server order.
    public func listDirectory(_ path: String) async throws -> [SFTPEntry] {
        let handle = try await openHandle(.opendir, { $0.string(path) })
        var entries: [SFTPEntry] = []
        do {
            while true {
                let reply = try await call(.readdir, { $0.string(handle) })
                if case .status(.eof, _) = reply { break }
                guard case .name(let batch) = reply else { try checkStatus(reply); throw SFTPError.unexpectedPacket("readdir reply") }
                entries += batch.filter { $0.name != "." && $0.name != ".." }
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
        return entries
    }

    /// Creates a directory. `permissions` defaults to the server's umask behavior.
    public func mkdir(_ path: String, permissions: UInt32? = nil) async throws {
        try checkStatus(try await call(.mkdir, {
            $0.string(path)
            $0.attributes(SFTPAttributes(permissions: permissions))
        }))
    }

    /// Removes a file or symlink.
    public func remove(_ path: String) async throws {
        try checkStatus(try await call(.remove, { $0.string(path) }))
    }

    /// Removes an empty directory.
    public func rmdir(_ path: String) async throws {
        try checkStatus(try await call(.rmdir, { $0.string(path) }))
    }

    /// Renames `source` to `destination`. v3 servers fail if `destination` exists.
    public func rename(_ source: String, to destination: String) async throws {
        try checkStatus(try await call(.rename, {
            $0.string(source)
            $0.string(destination)
        }))
    }

    // MARK: - Reading

    /// Reads up to `maxBytes` from the start of `path`. Longer files are truncated.
    public func readFile(_ path: String, maxBytes: Int = 16 * 1024 * 1024) async throws -> Data {
        let handle = try await openFile(path, flags: .read)
        var data = Data()
        do {
            try await readChunks(handle: handle, limit: UInt64(max(0, maxBytes))) { offset, chunk in
                let end = Int(offset) + chunk.count
                if data.count < end { data.count = end }
                data.replaceSubrange(Int(offset)..<end, with: chunk)
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
        return data
    }

    /// Streams `remote` into `localURL` (created or replaced) without buffering
    /// the whole file.
    public func download(
        _ remote: String,
        to localURL: URL,
        progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil
    ) async throws {
        let handle = try await openFile(remote, flags: .read)
        do {
            let total = (try? attributes(try await call(.fstat, { $0.string(handle) })))?.size
            guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
                throw SFTPError.failure("cannot create \(localURL.path)")
            }
            let file = try FileHandle(forWritingTo: localURL)
            defer { try? file.close() }
            var received: UInt64 = 0
            var end: UInt64 = 0
            try await readChunks(handle: handle, limit: .max) { offset, chunk in
                try file.seek(toOffset: offset)
                try file.write(contentsOf: chunk)
                received += UInt64(chunk.count)
                end = max(end, offset + UInt64(chunk.count))
                progress?(SFTPTransferProgress(bytesTransferred: received, totalBytes: total))
            }
            try file.truncate(atOffset: end)
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
    }

    /// Pipelined READ loop. `sink` receives each chunk with its file offset;
    /// chunks may arrive out of order when the server returns short reads.
    private func readChunks(
        handle: Data,
        limit: UInt64,
        sink: (UInt64, Data) throws -> Void
    ) async throws {
        var inFlight: [(id: UInt32, offset: UInt64, length: UInt32)] = []
        var nextOffset: UInt64 = 0
        var reachedEOF = false
        defer { discard(inFlight.map(\.id)) }

        while true {
            while !reachedEOF, inFlight.count < Self.window, nextOffset < limit {
                let length = UInt32(min(UInt64(Self.chunkSize), limit - nextOffset))
                inFlight.append((try await sendRead(handle, offset: nextOffset, length: length), nextOffset, length))
                nextOffset += UInt64(length)
            }
            guard !inFlight.isEmpty else { return }
            let current = inFlight.removeFirst()
            let reply = try await response(current.id)
            switch reply {
            case .data(let chunk) where !chunk.isEmpty:
                let count = min(chunk.count, Int(current.length))
                try sink(current.offset, chunk.prefix(count))
                if count < current.length {
                    // Short read: ask for the rest of this range again.
                    let offset = current.offset + UInt64(count)
                    let length = current.length - UInt32(count)
                    inFlight.append((try await sendRead(handle, offset: offset, length: length), offset, length))
                }
            case .data, .status(.eof, _):
                reachedEOF = true
            default:
                try checkStatus(reply)
                throw SFTPError.unexpectedPacket("read reply")
            }
        }
    }

    private func sendRead(_ handle: Data, offset: UInt64, length: UInt32) async throws -> UInt32 {
        try await send(.read) {
            $0.string(handle)
            $0.uint64(offset)
            $0.uint32(length)
        }
    }

    // MARK: - Writing

    /// Creates or truncates `path` and writes `data` to it.
    public func writeFile(_ path: String, data: Data) async throws {
        var offset = 0
        try await writeChunks(path: path) {
            guard offset < data.count else { return nil }
            let end = min(offset + Self.chunkSize, data.count)
            defer { offset = end }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
        } progress: { _ in }
    }

    /// Streams `localURL` to `remote`, creating or truncating it.
    public func upload(
        from localURL: URL,
        to remote: String,
        progress: (@Sendable (SFTPTransferProgress) -> Void)? = nil
    ) async throws {
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value
        try await writeChunks(path: remote) {
            let chunk = try file.read(upToCount: Self.chunkSize) ?? Data()
            return chunk.isEmpty ? nil : chunk
        } progress: { sent in
            progress?(SFTPTransferProgress(bytesTransferred: sent, totalBytes: total))
        }
    }

    /// Pipelined WRITE loop fed by `nextChunk` until it returns `nil`.
    private func writeChunks(
        path: String,
        nextChunk: () throws -> Data?,
        progress: (UInt64) -> Void
    ) async throws {
        let handle = try await openFile(path, flags: [.write, .create, .truncate])
        var inFlight: [(id: UInt32, length: Int)] = []
        do {
            defer { discard(inFlight.map(\.id)) }
            var offset: UInt64 = 0
            var acknowledged: UInt64 = 0
            var exhausted = false
            while true {
                while !exhausted, inFlight.count < Self.window {
                    guard let chunk = try nextChunk() else { exhausted = true; break }
                    let id = try await send(.write) {
                        $0.string(handle)
                        $0.uint64(offset)
                        $0.string(chunk)
                    }
                    inFlight.append((id, chunk.count))
                    offset += UInt64(chunk.count)
                }
                guard !inFlight.isEmpty else { break }
                let current = inFlight.removeFirst()
                try checkStatus(try await response(current.id))
                acknowledged += UInt64(current.length)
                progress(acknowledged)
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        try await closeHandle(handle)
    }

    // MARK: - Handles

    private func openFile(_ path: String, flags: SFTPOpenFlags) async throws -> Data {
        try await openHandle(.open) {
            $0.string(path)
            $0.uint32(flags.rawValue)
            $0.attributes(SFTPAttributes())
        }
    }

    private func openHandle(_ type: SFTPPacketType, _ build: (inout SFTPWriter) -> Void) async throws -> Data {
        let reply = try await call(type, build)
        guard case .handle(let handle) = reply else {
            try checkStatus(reply)
            throw SFTPError.unexpectedPacket("expected handle")
        }
        return handle
    }

    private func closeHandle(_ handle: Data) async throws {
        try checkStatus(try await call(.close, { $0.string(handle) }))
    }

    // MARK: - Request plumbing

    private func call(_ type: SFTPPacketType, _ build: (inout SFTPWriter) -> Void) async throws -> SFTPResponse {
        try await response(try await send(type, build))
    }

    /// Writes one request and reserves its reply slot. The reply may arrive
    /// before ``response(_:)`` is awaited; the slot holds it until then.
    private func send(_ type: SFTPPacketType, _ build: (inout SFTPWriter) -> Void) async throws -> UInt32 {
        guard !lost else { throw SFTPError.connectionLost }
        let id = nextID
        nextID &+= 1
        var writer = SFTPWriter()
        writer.uint32(id)
        build(&writer)
        slots[id] = .waiting
        do {
            try await session.write(writer.packet(type: type))
        } catch {
            slots[id] = nil
            connectionLost()
            throw SFTPError.connectionLost
        }
        return id
    }

    private func response(_ id: UInt32) async throws -> SFTPResponse {
        switch slots[id] {
        case .done(let result):
            slots[id] = nil
            return try result.get()
        case .waiting:
            return try await withCheckedThrowingContinuation { continuation in
                slots[id] = .awaiting(continuation)
            }
        case .awaiting, .discarded, nil:
            throw SFTPError.unexpectedPacket("no request \(id)")
        }
    }

    /// Abandons replies nobody will await (after an error mid-transfer).
    private func discard(_ ids: [UInt32]) {
        for id in ids {
            if case .done = slots[id] { slots[id] = nil } else if slots[id] != nil { slots[id] = .discarded }
        }
    }

    private func resolve(_ id: UInt32, with result: Result<SFTPResponse, any Error>) {
        switch slots[id] {
        case .waiting:
            slots[id] = .done(result)
        case .awaiting(let continuation):
            slots[id] = nil
            continuation.resume(with: result)
        case .discarded:
            slots[id] = nil
        case .done, nil:
            break
        }
    }

    // MARK: - Inbound

    private func startReader() {
        let events = session.events
        reader = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if case .stdout(let data) = event { await self.receive(data) }
            }
            await self?.connectionLost()
        }
    }

    private func receive(_ data: Data) {
        guard !lost else { return }
        framer.append(data)
        do {
            while let packet = try framer.next() {
                try dispatch(type: packet.type, payload: packet.payload)
            }
        } catch {
            // A framing or decoding error leaves the stream unusable.
            connectionLost()
            Task { await session.close() }
        }
    }

    private func dispatch(type: UInt8, payload: Data) throws {
        var reader = SFTPReader(payload)
        if type == SFTPPacketType.version.rawValue {
            let serverVersion = try reader.uint32()
            version?.resume(returning: serverVersion)
            version = nil
            return
        }
        let id = try reader.uint32()
        do {
            resolve(id, with: .success(try reader.response(type: type)))
        } catch {
            resolve(id, with: .failure(error))
        }
    }

    private func connectionLost() {
        guard !lost else { return }
        lost = true
        version?.resume(throwing: SFTPError.connectionLost)
        version = nil
        let pending = slots
        slots.removeAll()
        for (_, slot) in pending {
            if case .awaiting(let continuation) = slot {
                continuation.resume(throwing: SFTPError.connectionLost)
            }
        }
        // Replies that arrived but were never awaited now fail on lookup.
        for (id, slot) in pending {
            if case .done = slot { slots[id] = slot } else if case .waiting = slot { slots[id] = .done(.failure(SFTPError.connectionLost)) }
        }
    }

    // MARK: - Reply helpers

    private func attributes(_ reply: SFTPResponse) throws -> SFTPAttributes {
        guard case .attrs(let attributes) = reply else {
            try checkStatus(reply)
            throw SFTPError.unexpectedPacket("expected attrs")
        }
        return attributes
    }

    /// Succeeds on `SSH_FX_OK`, throws the mapped error for any other status,
    /// and throws `unexpectedPacket` for non-status replies.
    private func checkStatus(_ reply: SFTPResponse) throws {
        guard case .status(let code, let message) = reply else {
            throw SFTPError.unexpectedPacket("expected status")
        }
        switch code {
        case .ok: return
        case .noSuchFile: throw SFTPError.noSuchFile
        case .permissionDenied: throw SFTPError.permissionDenied
        case .eof: throw SFTPError.failure("unexpected end of file")
        default: throw SFTPError.failure(message.isEmpty ? "status \(code)" : message)
        }
    }
}
