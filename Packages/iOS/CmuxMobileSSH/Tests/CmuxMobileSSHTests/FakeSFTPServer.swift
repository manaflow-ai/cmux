@testable import CmuxMobileSSH
import Foundation

/// An in-memory SFTP v3 server on a fake channel: the client writes request
/// packets, the server answers on `events` in order. Paths are absolute;
/// the login directory is `/home/me`. `maxRead` caps each READ reply to
/// exercise the client's short-read path; `dropAfterRequests` closes the
/// channel after that many requests.
final class FakeSFTPServer: SFTPChannel, @unchecked Sendable {
    enum Node: Equatable {
        case file(Data)
        case directory
    }

    struct State {
        var nodes: [String: Node] = ["/": .directory, "/home": .directory, "/home/me": .directory]
        var framer = SFTPFramer()
        var handles: [Data: (path: String, listed: Bool)] = [:]
        var nextHandle = 0
        var requests = 0
        var closed = false
        var maxRead = Int.max
        var dropAfterRequests: Int?
        var writes: [(path: String, offset: UInt64)] = []
        var openFlags: [UInt32] = []
    }

    let events: AsyncStream<SSHSessionEvent>
    private let continuation: AsyncStream<SSHSessionEvent>.Continuation
    let state = Locked(State())

    init() {
        (events, continuation) = AsyncStream.makeStream(of: SSHSessionEvent.self)
    }

    func set(_ path: String, _ node: Node) {
        state.withLock { $0.nodes[path] = node }
    }

    func node(_ path: String) -> Node? {
        state.withLock { $0.nodes[path] }
    }

    func write(_ data: Data) async throws {
        let replies: [Data]? = state.withLock { state in
            guard !state.closed else { return nil }
            state.framer.append(data)
            var out: [Data] = []
            while let packet = try? state.framer.next() {
                state.requests += 1
                if let limit = state.dropAfterRequests, state.requests > limit {
                    state.closed = true
                    return out
                }
                out.append(Self.handle(type: packet.type, payload: packet.payload, state: &state))
            }
            return out
        }
        guard let replies else { throw SFTPError.connectionLost }
        for reply in replies { continuation.yield(.stdout(reply)) }
        if state.withLock({ $0.closed }) {
            continuation.yield(.closed)
            continuation.finish()
        }
    }

    func close() async {
        state.withLock { $0.closed = true }
        continuation.yield(.closed)
        continuation.finish()
    }

    // MARK: Protocol

    private static func handle(type: UInt8, payload: Data, state: inout State) -> Data {
        var reader = SFTPReader(payload)
        if type == SFTPPacketType.initialize.rawValue {
            var writer = SFTPWriter()
            writer.uint32(3)
            return writer.packet(type: .version)
        }
        guard let id = try? reader.uint32(), let kind = SFTPPacketType(rawValue: type) else {
            return status(0, 4, "bad request")
        }
        switch kind {
        case .realpath:
            let path = (try? reader.utf8()) ?? ""
            let resolved = path == "." || path.isEmpty ? "/home/me" : path
            var writer = SFTPWriter()
            writer.uint32(id)
            writer.uint32(1)
            writer.string(resolved)
            writer.string(resolved)
            writer.attributes(SFTPAttributes())
            return writer.packet(type: .name)
        case .stat, .lstat:
            let path = (try? reader.utf8()) ?? ""
            guard let node = state.nodes[path] else { return status(id, 2, "no such file") }
            return attrs(id, node)
        case .fstat:
            guard let handle = try? reader.string(), let open = state.handles[handle],
                  let node = state.nodes[open.path] else { return status(id, 4, "bad handle") }
            return attrs(id, node)
        case .opendir:
            let path = (try? reader.utf8()) ?? ""
            guard state.nodes[path] == .directory else { return status(id, 2, "no such directory") }
            return handle(id, path: path, state: &state)
        case .readdir:
            guard let handle = try? reader.string(), let open = state.handles[handle] else { return status(id, 4, "bad handle") }
            if open.listed { return status(id, 1, "eof") }
            state.handles[handle]?.listed = true
            let prefix = open.path == "/" ? "/" : open.path + "/"
            let children = state.nodes.keys.filter { $0.hasPrefix(prefix) && $0 != open.path && !$0.dropFirst(prefix.count).contains("/") }.sorted()
            var writer = SFTPWriter()
            writer.uint32(id)
            writer.uint32(UInt32(children.count + 2))
            for name in [".", ".."] {
                writer.string(name)
                writer.string(name)
                writer.attributes(SFTPAttributes(permissions: 0o040755))
            }
            for child in children {
                let name = String(child.dropFirst(prefix.count))
                writer.string(name)
                writer.string("-rw-r--r-- 1 me me " + name)
                writer.attributes(attributes(state.nodes[child]!))
            }
            return writer.packet(type: .name)
        case .open:
            let path = (try? reader.utf8()) ?? ""
            let flags = (try? reader.uint32()) ?? 0
            state.openFlags.append(flags)
            let exists = state.nodes[path] != nil
            if flags & 0x08 != 0 {
                if !exists || flags & 0x10 != 0 { state.nodes[path] = .file(Data()) }
            } else if !exists {
                return status(id, 2, "no such file")
            }
            guard case .file = state.nodes[path] else { return status(id, 4, "is a directory") }
            return handle(id, path: path, state: &state)
        case .read:
            guard let handle = try? reader.string(), let offset = try? reader.uint64(), let length = try? reader.uint32(),
                  let open = state.handles[handle], case .file(let data) = state.nodes[open.path] else {
                return status(id, 4, "bad handle")
            }
            guard offset < UInt64(data.count) else { return status(id, 1, "eof") }
            let end = min(data.count, Int(offset) + min(Int(length), state.maxRead))
            var writer = SFTPWriter()
            writer.uint32(id)
            writer.string(data.subdata(in: Int(offset)..<end))
            return writer.packet(type: .data)
        case .write:
            guard let handle = try? reader.string(), let offset = try? reader.uint64(), let chunk = try? reader.string(),
                  let open = state.handles[handle], case .file(var data) = state.nodes[open.path] else {
                return status(id, 4, "bad handle")
            }
            let end = Int(offset) + chunk.count
            if data.count < end { data.append(Data(count: end - data.count)) }
            data.replaceSubrange(Int(offset)..<end, with: chunk)
            state.nodes[open.path] = .file(data)
            state.writes.append((open.path, offset))
            return status(id, 0, "")
        case .close:
            guard let handle = try? reader.string(), state.handles.removeValue(forKey: handle) != nil else {
                return status(id, 4, "bad handle")
            }
            return status(id, 0, "")
        case .mkdir:
            let path = (try? reader.utf8()) ?? ""
            guard state.nodes[path] == nil else { return status(id, 4, "exists") }
            state.nodes[path] = .directory
            return status(id, 0, "")
        case .rmdir:
            let path = (try? reader.utf8()) ?? ""
            guard state.nodes[path] == .directory else { return status(id, 2, "no such directory") }
            guard !state.nodes.keys.contains(where: { $0.hasPrefix(path + "/") }) else { return status(id, 4, "not empty") }
            state.nodes[path] = nil
            return status(id, 0, "")
        case .remove:
            let path = (try? reader.utf8()) ?? ""
            guard case .file = state.nodes[path] else { return status(id, 2, "no such file") }
            state.nodes[path] = nil
            return status(id, 0, "")
        case .rename:
            let source = (try? reader.utf8()) ?? ""
            let destination = (try? reader.utf8()) ?? ""
            guard let node = state.nodes[source] else { return status(id, 2, "no such file") }
            guard state.nodes[destination] == nil else { return status(id, 4, "exists") }
            if source.hasPrefix("/root-only") { return status(id, 3, "denied") }
            state.nodes[source] = nil
            state.nodes[destination] = node
            return status(id, 0, "")
        default:
            return status(id, 8, "unsupported")
        }
    }

    private static func handle(_ id: UInt32, path: String, state: inout State) -> Data {
        state.nextHandle += 1
        let handle = Data("h\(state.nextHandle)".utf8)
        state.handles[handle] = (path, false)
        var writer = SFTPWriter()
        writer.uint32(id)
        writer.string(handle)
        return writer.packet(type: .handle)
    }

    private static func attributes(_ node: Node) -> SFTPAttributes {
        switch node {
        case .directory: SFTPAttributes(size: 0, permissions: 0o040755, accessTime: Date(timeIntervalSince1970: 1_700_000_000),
                                        modificationTime: Date(timeIntervalSince1970: 1_700_000_000))
        case .file(let data): SFTPAttributes(size: UInt64(data.count), permissions: 0o100644,
                                             accessTime: Date(timeIntervalSince1970: 1_700_000_000),
                                             modificationTime: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    private static func attrs(_ id: UInt32, _ node: Node) -> Data {
        var writer = SFTPWriter()
        writer.uint32(id)
        writer.attributes(attributes(node))
        return writer.packet(type: .attrs)
    }

    private static func status(_ id: UInt32, _ code: UInt32, _ message: String) -> Data {
        var writer = SFTPWriter()
        writer.uint32(id)
        writer.uint32(code)
        writer.string(message)
        writer.string("")
        return writer.packet(type: .status)
    }
}

/// A lock around a value (the test host's deployment target predates `Mutex`).
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
