import Darwin
import Foundation

/// The live adapter is deliberately kept in the Debug host instead of the
/// app's production target. It has a tiny read allowlist and opens a fresh
/// request socket for every read; the long-lived socket is used only for
/// `events.stream`.
enum LiveProjectionUpdate: Sendable {
    case snapshot(ProjectionSnapshot)
    case failure(String)
}

struct LiveProjectionClient: Sendable {
    let socketPath: String

    func updates() -> AsyncStream<LiveProjectionUpdate> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [socketPath] in
                do {
                    let events = try UnixLineSocket(path: socketPath)
                    try events.send(method: "events.stream", params: ["include_heartbeats": false])
                    let ack = try events.readRequiredFrame()
                    var cursor = try EventCursor(ack: ack)

                    // Stream-first: the subscription is established before any
                    // snapshot read, so a change cannot land in a bootstrap gap.
                    let request = LiveControlClient(socketPath: socketPath)
                    let first = try request.fetch(expectedIdentity: nil)
                    var state = LiveProjectionState(identity: first.identity,
                                                     topologySequence: first.topologySequence)
                    try state.accept(first)
                    continuation.yield(.snapshot(first.snapshot))

                    let refreshes = ProjectionRefreshQueue(client: request,
                                                           identity: first.identity,
                                                           topologySequence: first.topologySequence,
                                                           continuation: continuation)
                    while let frame = try events.readFrame() {
                        switch try cursor.accept(frame: frame) {
                        case .heartbeat:
                            continue
                        case .event:
                            // The actor coalesces a burst of notifications into
                            // one or more fresh snapshots. It never applies an
                            // event payload as if it were authoritative state.
                            await refreshes.notify()
                        }
                    }
                    await refreshes.finish(message: "events.stream closed")
                } catch {
                    continuation.yield(.failure(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct LiveControlClient: Sendable {
    let socketPath: String

    func fetch(expectedIdentity: IdentifyFingerprint?) throws -> LiveFetch {
        let identify = try request(method: "system.identify")
        let identity = try IdentifyFingerprint(result: identify)
        guard identity.protocolVersion == 1 else {
            throw LiveProjectionError.invalidIdentify
        }
        if let expectedIdentity, identity != expectedIdentity {
            throw LiveProjectionError.identityChanged
        }
        let required = Set(["system.identify", "snapshot.get", "events.stream"])
        guard required.isSubset(of: identity.methods) else {
            throw LiveProjectionError.missingReadMethods
        }

        let snapshot = try request(method: "snapshot.get")
        let topology = try TopologyProjection(result: snapshot)
        return LiveFetch(identity: identity, topologySequence: topology.sequence,
                         snapshot: topology.snapshot)
    }

    private func request(method: String) throws -> [String: Any] {
        // Keep the allowlist next to the actual transport. A future UI action
        // cannot accidentally turn this adapter into a mutating client.
        guard method == "system.identify" || method == "snapshot.get" else {
            throw LiveProjectionError.methodNotAllowed(method)
        }
        let socket = try UnixLineSocket(path: socketPath)
        try socket.send(method: method, params: [:])
        let frame = try socket.readRequiredFrame()
        guard (frame["ok"] as? Bool) == true,
              let result = frame["result"] as? [String: Any] else {
            throw LiveProjectionError.requestRejected(method, errorMessage(frame))
        }
        return result
    }
}

private struct LiveFetch: Sendable {
    let identity: IdentifyFingerprint
    let topologySequence: UInt64
    let snapshot: ProjectionSnapshot
}

private struct LiveProjectionState {
    let identity: IdentifyFingerprint
    var topologySequence: UInt64

    mutating func accept(_ fetch: LiveFetch) throws {
        guard fetch.identity == identity else { throw LiveProjectionError.identityChanged }
        guard fetch.topologySequence >= topologySequence else {
            throw LiveProjectionError.topologyReset
        }
        topologySequence = fetch.topologySequence
    }
}

/// Serializes reads after event notifications. A second notification while a
/// read is in flight sets `requested` and is folded into the next read rather
/// than starting an unbounded request storm.
private actor ProjectionRefreshQueue {
    let client: LiveControlClient
    let identity: IdentifyFingerprint
    var topologySequence: UInt64
    let continuation: AsyncStream<LiveProjectionUpdate>.Continuation
    var requested = false
    var running = false
    var stopped = false

    init(client: LiveControlClient, identity: IdentifyFingerprint,
         topologySequence: UInt64,
         continuation: AsyncStream<LiveProjectionUpdate>.Continuation) {
        self.client = client
        self.identity = identity
        self.topologySequence = topologySequence
        self.continuation = continuation
    }

    func notify() {
        guard !stopped else { return }
        requested = true
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    func finish(message: String) {
        guard !stopped else { return }
        stopped = true
        continuation.yield(.failure(message))
    }

    private func drain() async {
        while requested && !stopped {
            requested = false
            do {
                let fetch = try await Task.detached(priority: .userInitiated) { [client, identity] in
                    try client.fetch(expectedIdentity: identity)
                }.value
                guard fetch.topologySequence >= topologySequence else {
                    throw LiveProjectionError.topologyReset
                }
                topologySequence = fetch.topologySequence
                continuation.yield(.snapshot(fetch.snapshot))
            } catch {
                stopped = true
                continuation.yield(.failure(error.localizedDescription))
            }
        }
        running = false
    }
}

struct IdentifyFingerprint: Equatable, Sendable {
    let app: String
    let version: String
    let build: String
    let bundleID: String?
    let processID: Int64
    let protocolVersion: Int64
    let socketPath: String?
    let methods: Set<String>

    init(result: [String: Any]) throws {
        guard let app = result["app"] as? String, !app.isEmpty,
              let version = result["version"] as? String,
              let build = result["build"] as? String,
              let processID = jsonInt(result["pid"]),
              let protocolVersion = jsonInt(result["protocol_version"]),
              let methods = result["methods"] as? [String] else {
            throw LiveProjectionError.invalidIdentify
        }
        self.app = app
        self.version = version
        self.build = build
        self.bundleID = result["bundle_id"] as? String
        self.processID = processID
        self.protocolVersion = protocolVersion
        self.socketPath = result["socket_path"] as? String
        self.methods = Set(methods)
    }
}

enum EventKind: Equatable { case event, heartbeat }

struct EventCursor {
    let bootID: String
    var sequence: Int64

    init(ack: [String: Any]) throws {
        guard ack["type"] as? String == "ack",
              ack["protocol"] as? String == "cmux-events",
              jsonInt(ack["version"]) == 1,
              let bootID = ack["boot_id"] as? String, !bootID.isEmpty,
              let resume = ack["resume"] as? [String: Any],
              let latest = jsonInt(resume["latest_seq"]),
              jsonBool(resume["gap"]) == false else {
            throw LiveProjectionError.invalidEventAck
        }
        self.bootID = bootID
        self.sequence = latest
    }

    mutating func accept(frame: [String: Any]) throws -> EventKind {
        guard frame["protocol"] as? String == "cmux-events",
              jsonInt(frame["version"]) == 1,
              frame["boot_id"] as? String == bootID else {
            throw LiveProjectionError.eventStreamReset
        }
        switch frame["type"] as? String {
        case "heartbeat":
            guard let latest = jsonInt(frame["latest_seq"]), latest >= sequence else {
                throw LiveProjectionError.eventSequenceRegressed
            }
            sequence = latest
            return .heartbeat
        case "event":
            guard let next = jsonInt(frame["seq"]), next == sequence + 1 else {
                throw LiveProjectionError.eventSequenceGap
            }
            sequence = next
            return .event
        default:
            throw LiveProjectionError.invalidEventFrame
        }
    }
}

enum LiveProjectionError: LocalizedError {
    case invalidIdentify
    case missingReadMethods
    case identityChanged
    case topologyReset
    case invalidEventAck
    case eventStreamReset
    case eventSequenceRegressed
    case eventSequenceGap
    case invalidEventFrame
    case methodNotAllowed(String)
    case requestRejected(String, String)
    case socket(String)
    case frameTooLarge
    case malformedFrame

    var errorDescription: String? {
        switch self {
        case .invalidIdentify: return "system.identify did not provide a complete cmux identity"
        case .missingReadMethods: return "the attached socket does not advertise the required read methods"
        case .identityChanged: return "the attached cmux identity changed; projection stopped"
        case .topologyReset: return "snapshot topology sequence reset; projection stopped"
        case .invalidEventAck: return "events.stream did not return a compatible, gap-free ack"
        case .eventStreamReset: return "events.stream boot identity changed; projection stopped"
        case .eventSequenceRegressed: return "events.stream sequence regressed; projection stopped"
        case .eventSequenceGap: return "events.stream sequence gap; projection stopped"
        case .invalidEventFrame: return "events.stream returned an unknown frame"
        case .methodNotAllowed(let method): return "read-only adapter refused method \(method)"
        case .requestRejected(let method, let message): return "\(method) rejected: \(message)"
        case .socket(let message): return "socket: \(message)"
        case .frameTooLarge: return "socket frame exceeds 8 MiB"
        case .malformedFrame: return "socket returned malformed JSON"
        }
    }
}

private final class UnixLineSocket: @unchecked Sendable {
    private static let maxFrameBytes = 8 * 1024 * 1024
    private let handle: FileHandle
    private var pending = Data()

    init(path: String) throws {
        try Self.validateSocketPath(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LiveProjectionError.socket(String(cString: strerror(errno))) }
        var noSigPipe: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw LiveProjectionError.socket(message)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            Darwin.close(descriptor)
            throw LiveProjectionError.socket("path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard connected == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw LiveProjectionError.socket(message)
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func validateSocketPath(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid() else {
            throw LiveProjectionError.socket("attach path must be a current-user Unix socket")
        }
    }

    func send(method: String, params: [String: Any]) throws {
        let object: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        try handle.write(contentsOf: data)
    }

    func readRequiredFrame() throws -> [String: Any] {
        guard let frame = try readFrame() else { throw LiveProjectionError.socket("peer closed the socket") }
        return frame
    }

    func readFrame() throws -> [String: Any]? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw LiveProjectionError.malformedFrame
                }
                return object
            }
            guard pending.count <= Self.maxFrameBytes else { throw LiveProjectionError.frameTooLarge }
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            guard !chunk.isEmpty else {
                if pending.isEmpty { return nil }
                throw LiveProjectionError.malformedFrame
            }
            pending.append(chunk)
        }
    }
}

private func errorMessage(_ frame: [String: Any]) -> String {
    (frame["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
}

private func jsonInt(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let integer = value as? Int64 { return integer }
    if let integer = value as? Int { return Int64(integer) }
    return nil
}

private func jsonBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
}

private struct TopologyProjection {
    let sequence: UInt64
    let snapshot: ProjectionSnapshot

    init(result: [String: Any]) throws {
        guard let sequence = jsonInt(result["sequence"]), sequence >= 0,
              let topology = result["topology"] as? [String: Any],
              jsonBool(topology["loaded"]) == true,
              let workspaces = topology["workspaces"] as? [[String: Any]] else {
            throw LiveProjectionError.requestRejected("snapshot.get", "topology is not loaded")
        }
        let focus = topology["focus"] as? [String: Any]
        let selected = focus?["workspace"] as? String
        let mapped = workspaces.compactMap(ProjectionWorkspace.init(topologyObject:))
        guard mapped.count == workspaces.count else {
            throw LiveProjectionError.requestRejected("snapshot.get", "topology contains an invalid workspace")
        }
        self.sequence = UInt64(sequence)
        self.snapshot = ProjectionSnapshot(
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            selectedWorkspaceID: selected,
            workspaces: mapped
        )
    }
}

private extension ProjectionWorkspace {
    init?(topologyObject object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        let name = (object["name"] as? String) ?? (object["title"] as? String) ?? id
        let screens = object["screens"] as? [[String: Any]] ?? []
        let tabs = screens.flatMap { $0["panes"] as? [[String: Any]] ?? [] }
            .flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            .compactMap(ProjectionTab.init(topologyObject:))
        self.init(id: id, name: name, tabs: tabs)
    }
}

private extension ProjectionTab {
    init?(topologyObject object: [String: Any]) {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        let title = (object["title"] as? String) ?? (object["name"] as? String) ?? id
        let subtitle = (object["agent"] as? String)
            ?? (object["cwd"] as? String)
            ?? (object["url"] as? String)
            ?? (object["git_branch"] as? String)
            ?? (object["page"] as? String)
        let unread = (object["unread"] as? Bool) ?? ((object["unread"] as? NSNumber)?.boolValue ?? false)
        self.init(id: id, title: title, subtitle: subtitle, unread: unread)
    }
}
