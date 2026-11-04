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
            Thread.detachNewThread { [self] in pump(from: daemon, to: client, counting: nil); pair.ended() }
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
    }

    /// Copies `source` to `sink` until either ends; with `counting`, counts each request line's command.
    private func pump(from source: Int32, to sink: Int32, counting: Connection?) {
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
            guard let counting else { continue }
            line.append(contentsOf: buffer[0..<read])
            while let newline = line.firstIndex(of: UInt8(ascii: "\n")) {
                note(line[line.startIndex..<newline], on: counting)
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
