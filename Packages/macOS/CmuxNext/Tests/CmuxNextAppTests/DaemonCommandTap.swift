import CmuxNextDaemon
import Darwin
import Foundation

/// A Unix-socket relay between a test's app and its daemon that counts the commands the app sends, by name
/// (`"cmd":"…"` of each request line), and passes every byte on unchanged both ways. A test reads what the
/// app asks the daemon for (`count(_:)`) without a hook in the app (#32408).
///
/// A `list-workspaces` the store sends for its snapshot (`DaemonConnection.snapshot()`: the tree pipelined with
/// `list-saved-tab-groups` or `list-personal`) counts as ``snapshotRead``; any other as itself.
nonisolated final class DaemonCommandTap: @unchecked Sendable {
    /// The socket the app connects to.
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var target: String?
    /// A `list-workspaces` line whose kind the next request line decides (a snapshot's or a read of its own).
    private var pendingTreeRead = false
    /// The command name a store snapshot's `list-workspaces` counts under.
    static let snapshotRead = "list-workspaces (store snapshot)"
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
            // task-owner: one relayed connection's two directions; each ends at its side's end of stream
            Thread.detachNewThread { [self] in pump(from: client, to: daemon, counting: true); pair.ended() }
            Thread.detachNewThread { [self] in pump(from: daemon, to: client, counting: false); pair.ended() }
        }
    }

    /// Copies `source` to `sink` until either ends; with `counting`, counts each request line's command.
    private func pump(from source: Int32, to sink: Int32, counting: Bool) {
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
            line.append(contentsOf: buffer[0..<read])
            guard counting else {
                while let newline = line.firstIndex(of: UInt8(ascii: "\n")) {
                    noteEvent(line[line.startIndex..<newline])
                    line.removeSubrange(line.startIndex...newline)
                }
                continue
            }
            while let newline = line.firstIndex(of: UInt8(ascii: "\n")) {
                note(line[line.startIndex..<newline])
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

    private var sequenceLog = 0
    private var lastCommand = "-"
    private func noteEvent(_ line: Data) {
        guard line.count < 200_000, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return }
        lock.withLock {
            if event == "tree-changed" { counts["DIAGTC after \(lastCommand)", default: 0] += 1 }
            if sequenceLog < 400, !["surface-output", "agent-presence", "scroll-changed", "title-changed"].contains(event) {
                sequenceLog += 1
                let entity = object["entity"] as? [String: Any]
                let screens = (entity?["screens"] as? [Any])?.count
                print("DIAGSEQ ev \(event) ws=\(object["workspace"] ?? "-") screens=\(screens.map(String.init) ?? "-")")
            }
        }
    }

    func diag() -> String {
        lock.withLock { counts.filter { $0.key.hasPrefix("DIAGTC") || $0.key == Self.snapshotRead }.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " | ") }
    }

    private func note(_ request: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let command = object["cmd"] as? String else { return }
        lock.withLock {
            lastCommand = command
            if sequenceLog < 400, !["identify", "set-client-info", "resize-attached-view", "set-client-sizing"].contains(command) {
                sequenceLog += 1
                print("DIAGSEQ cmd \(command)")
            }
            if pendingTreeRead {
                pendingTreeRead = false
                let snapshot = command == "list-personal" || command == "list-saved-tab-groups"
                counts[snapshot ? Self.snapshotRead : "list-workspaces", default: 0] += 1
            }
            if command == "list-workspaces" { pendingTreeRead = true } else { counts[command, default: 0] += 1 }
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
