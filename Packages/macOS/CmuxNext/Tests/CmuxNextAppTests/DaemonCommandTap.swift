import CmuxNextDaemon
import Darwin
import Foundation

/// A Unix-socket relay between a test's app and its daemon that counts the commands the app sends, by name
/// (`"cmd":"…"` of each request line), and passes every byte on unchanged both ways. A test reads what the
/// app asks the daemon for (`count(_:)`) without a hook in the app (#32408).
///
/// A `list-workspaces` the store sends for its snapshot (`DaemonConnection.snapshot()`: the tree pipelined with
/// `list-saved-tab-groups` or `list-personal`) counts as ``snapshotRead``, except each connection's first (its
/// connect), which counts as ``firstSnapshotRead``; any other `list-workspaces` counts as itself.
nonisolated final class DaemonCommandTap: @unchecked Sendable {
    /// The socket the app connects to.
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var target: String?
    /// The command name a store snapshot's `list-workspaces` counts under: a connection's later
    /// snapshots, each one the store asked for after its first (the connect's own, once per connection).
    static let snapshotRead = "list-workspaces (store snapshot)"
    /// A connection's first store snapshot (its connect), counted apart.
    static let firstSnapshotRead = "list-workspaces (first store snapshot)"
    private var closed = false
    /// Per command: requests answered, their total and longest reply time (seconds).
    private var replies: [String: (count: Int, total: Double, longest: Double, bytes: Int)] = [:]
    /// Event lines by event name (a session stream item by its item kind): how many, and their bytes.
    private var eventsByName: [String: (count: Int, bytes: Int)] = [:]
    /// Each resource's last upsert, to name the fields a repeated upsert changed (``changedFields``).
    private var lastUpsert: [String: [String: Any]] = [:]
    /// Per resource kind, how many repeated upserts changed each field ("(none)": the same record again).
    private var changedFields: [String: Int] = [:]
    /// Lines the daemon sent that answer no request (events), and their bytes.
    private var events = (count: 0, bytes: 0)
    /// Per stream: the highest delta revision delivered, and deltas whose revision was delivered before (replays).
    private var streamRevisions: [String: Int] = [:]
    private var replayedDeltas = 0
    /// The first delta seen with more than 100 changes: its line without the changes, and its change count.
    private var bigDelta: String?

    /// Reply times by command and the event volume so far (``Timings``).
    struct Timings: Sendable {
        var replies: [String: (count: Int, total: Double, longest: Double, bytes: Int)]
        var events: (count: Int, bytes: Int)
        var eventsByName: [String: (count: Int, bytes: Int)]
        var changedFields: [String: Int]
        var replayedDeltas: Int
        var streams: Int
        var bigDelta: String?
    }

    func timings() -> Timings {
        lock.withLock {
            Timings(replies: replies, events: events, eventsByName: eventsByName, changedFields: changedFields,
                    replayedDeltas: replayedDeltas, streams: streamRevisions.count, bigDelta: bigDelta)
        }
    }

    init() throws {
        path = "/tmp/cntap-\(UUID().uuidString.prefix(8).lowercased()).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            Darwin.close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        // task-owner: the tap's accept loop; ends when `close()` shuts the listener
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// `provider`'s endpoint with the socket this tap relays to it.
    func relaying(_ provider: @escaping DaemonConnection.EndpointProvider) -> DaemonConnection.EndpointProvider {
        { [self] in
            var endpoint = try await provider()
            lock.withLock { target = endpoint.socketPath }
            endpoint.socketPath = path
            return endpoint
        }
    }

    /// How many requests named `command` the app sent so far (a `list-workspaces` counts once the next request
    /// says whether it was a store snapshot's).
    func count(_ command: String) -> Int { lock.withLock { counts[command, default: 0] } }

    func close() {
        lock.withLock { closed = true }
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(path)
    }

    deinit { if !closed { close() } }

    /// The daemon's `server-stats` (with its resource projection and write path sections), read on a
    /// connection of its own, as its reply line; nil when no app connection named the daemon yet or the read fails.
    func serverStats() -> Data? {
        guard let target = lock.withLock({ target }) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = Self.address(target)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = Data(("{\"id\":1,\"cmd\":\"identify\"}\n" +
                            "{\"id\":2,\"cmd\":\"server-stats\",\"include\":[\"resource_projection\",\"write_path\"]}\n").utf8)
        guard request.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let read = Darwin.read(fd, &chunk, chunk.count)
            guard read > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<read])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["id"] as? Int == 2 {
                    return Data(line)
                }
            }
        }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            guard let target = lock.withLock({ target }) else {
                Darwin.close(client)
                continue
            }
            let daemon = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = Self.address(target)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(daemon, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard connected == 0 else {
                Darwin.close(client)
                Darwin.close(daemon)
                continue
            }
            let pair = Pair(client, daemon)
            let connection = Connection()
            // task-owner: one relayed connection's two directions; each ends at its side's end of stream
            Thread.detachNewThread { [self] in pump(from: client, to: daemon, counting: connection); pair.ended() }
            Thread.detachNewThread { [self] in pump(from: daemon, to: client, counting: nil, answering: connection); pair.ended() }
        }
    }

    /// One relayed connection's request state: whether its store took its first snapshot, and a
    /// `list-workspaces` whose kind the next request decides.
    private nonisolated final class Connection: @unchecked Sendable {  // touched only by its one request pump
        var pendingTreeRead = false
        var snapshots = 0
        /// The store pipelines `list-saved-tab-groups` with its snapshot's `list-workspaces` (where the
        /// daemon serves it); then a `list-personal` after a `list-workspaces` is the run's own refetch.
        var pipelinesSavedGroups = false
        /// Requests sent and not answered yet, by id: their command and when they went.
        var pending: [String: (command: String, sent: ContinuousClock.Instant)] = [:]
    }

    /// Copies `source` to `sink` until either ends; with `counting`, counts each request line's command.
    private func pump(from source: Int32, to sink: Int32, counting: Connection?, answering: Connection? = nil) {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let read = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            guard read > 0 else { break }
            var offset = 0
            while offset < read {
                let wrote = buffer.withUnsafeBytes { Darwin.write(sink, $0.baseAddress! + offset, read - offset) }
                guard wrote > 0 else { break }
                offset += wrote
            }
            guard offset == read else { break }
            guard counting != nil || answering != nil else { continue }
            line.append(contentsOf: buffer[0..<read])
            while let newline = line.firstIndex(of: UInt8(ascii: "\n")) {
                if let counting { note(line[line.startIndex..<newline], on: counting) }
                if let answering { answer(line[line.startIndex..<newline], on: answering) }
                line.removeSubrange(line.startIndex...newline)
            }
        }
        shutdown(sink, SHUT_WR)
        shutdown(source, SHUT_RD)
    }

    /// Closes both descriptors of a relayed connection once both of its directions ended.
    private nonisolated final class Pair: @unchecked Sendable {
        private let lock = NSLock()
        private var open = 2
        private let fds: (Int32, Int32)
        init(_ a: Int32, _ b: Int32) { fds = (a, b) }
        func ended() {
            let last = lock.withLock { open -= 1; return open == 0 }
            if last { Darwin.close(fds.0); Darwin.close(fds.1) }
        }
    }

    private func note(_ request: Data, on connection: Connection) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let command = object["cmd"] as? String else { return }
        lock.withLock {
            if connection.pendingTreeRead {
                connection.pendingTreeRead = false
                if command == "list-saved-tab-groups" { connection.pipelinesSavedGroups = true }
                let snapshot = command == "list-saved-tab-groups" || (command == "list-personal" && !connection.pipelinesSavedGroups)
                if snapshot { connection.snapshots += 1 }
                let name = !snapshot ? "list-workspaces" : connection.snapshots == 1 ? Self.firstSnapshotRead : Self.snapshotRead
                counts[name, default: 0] += 1
            }
            if command == "list-workspaces" { connection.pendingTreeRead = true } else { counts[command, default: 0] += 1 }
            if let id = Self.requestID(object["id"]) { connection.pending[id] = (command, .now) }
        }
    }

    /// A daemon line: the reply to a request (its time goes to ``replies``) or an event.
    private func answer(_ reply: Data, on connection: Connection) {
        let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        let id = Self.requestID(object?["id"])
        lock.withLock {
            guard let id, let sent = connection.pending.removeValue(forKey: id) else {
                events.count += 1
                events.bytes += reply.count
                var name = object?["event"] as? String ?? "?"
                if let item = (object?["item"] as? [String: Any])?["kind"] as? String { name += "/" + item }
                if let item = object?["item"] as? [String: Any], item["kind"] as? String == "delta" {
                    let stream = "\(ObjectIdentifier(connection)) \(object?["stream_id"] ?? object?["stream"] ?? "?")"
                    let revision = Int((item["revision"] as? String) ?? "") ?? -1
                    if revision <= streamRevisions[stream, default: -1] { replayedDeltas += 1 }
                    streamRevisions[stream] = max(revision, streamRevisions[stream, default: -1])
                    let changes = (item["changes"] as? [Any])?.count ?? 0
                    if bigDelta == nil, changes > 100 {
                        var head = object ?? [:]
                        var bare = item
                        bare["changes"] = changes
                        head["item"] = bare
                        let sample = ((item["changes"] as? [Any])?.prefix(3)).map { Array($0) } ?? []
                        head["sample_changes"] = sample
                        bigDelta = (try? JSONSerialization.data(withJSONObject: head)).map { String(decoding: $0, as: UTF8.self) }
                    }
                }
                // A delta's changes by resource (and op): which record grows.
                for change in (object?["item"] as? [String: Any])?["changes"] as? [[String: Any]] ?? [] {
                    let key = "change \(change["resource"] as? String ?? "?") \(change["op"] as? String ?? change["kind"] as? String ?? "")"
                    let size = (try? JSONSerialization.data(withJSONObject: change).count) ?? 0
                    if let resource = change["resource"] as? String, let id = change["id"] as? String {
                        let slot = resource + " " + id
                        if let was = lastUpsert[slot] {
                            let fields = Self.changed(was, change)
                            for field in fields.isEmpty ? ["(none)"] : fields { changedFields[resource + " " + field, default: 0] += 1 }
                        }
                        lastUpsert[slot] = change
                    }
                    var part = eventsByName[key] ?? (0, 0)
                    part.count += 1
                    part.bytes += size
                    eventsByName[key] = part
                }
                var entry = eventsByName[name] ?? (0, 0)
                entry.count += 1
                entry.bytes += reply.count
                eventsByName[name] = entry
                return
            }
            let seconds = (ContinuousClock.now - sent.sent) / .seconds(1)
            var entry = replies[sent.command] ?? (0, 0, 0, 0)
            entry.count += 1
            entry.bytes += reply.count
            entry.total += seconds
            entry.longest = max(entry.longest, seconds)
            replies[sent.command] = entry
        }
    }

    /// The keys (one level into objects, `extra.x`) whose values differ between two records.
    /// A request id as the pending map keys it: `cmux.protocol/2` sends a decimal string, older commands a number.
    private static func requestID(_ value: Any?) -> String? {
        switch value {
        case let number as NSNumber: number.stringValue
        case let string as String: string
        default: nil
        }
    }

    private static func changed(_ a: [String: Any], _ b: [String: Any]) -> [String] {
        var out: [String] = []
        for key in Set(a.keys).union(b.keys).sorted() where key != "seq" && key != "revision" {
            let x = a[key], y = b[key]
            if let x = x as? [String: Any], let y = y as? [String: Any] {
                out += changed(x, y).map { key + "." + $0 }
            } else if !same(x, y) {
                out.append(key)
            }
        }
        return out
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b)
        default: false
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { bytes in buffer.copyBytes(from: bytes.prefix(capacity - 1)) }
        }
        return address
    }
}
