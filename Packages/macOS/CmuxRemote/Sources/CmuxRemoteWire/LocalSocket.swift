// SPDX-License-Identifier: GPL-3.0-or-later
public import Darwin
public import Foundation
import os

/// One end of a connected Unix stream socket (or a pipe pair), read as JSON
/// lines. Reads block the calling thread, so each channel is read on its own
/// thread; writes are serialized by a lock and never block on a reader.
public final class LineChannel: Sendable {
    public let readDescriptor: Int32
    public let writeDescriptor: Int32
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let writeLock = OSAllocatedUnfairLock(initialState: ())

    private struct State: Sendable {
        var buffer = LineBuffer()
        var queued: [Data] = []
        var closed = false
    }

    /// A socket: one descriptor both ways.
    public convenience init(socket descriptor: Int32) {
        self.init(read: descriptor, write: descriptor)
    }

    public init(read: Int32, write: Int32) {
        readDescriptor = read
        writeDescriptor = write
        var on: Int32 = 1
        _ = setsockopt(write, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The next line, or nil at end of stream (or a line over the limit).
    public func readLine() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let next = state.withLock { state -> Data?? in
                if !state.queued.isEmpty { return .some(state.queued.removeFirst()) }
                return state.closed ? .some(nil) : .none
            }
            if let next { return next }
            let count = Darwin.read(readDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                state.withLock { $0.closed = true }
                return nil
            }
            let ok = state.withLock { state -> Bool in
                guard let lines = state.buffer.append(Data(bytes[0..<count])) else { return false }
                state.queued.append(contentsOf: lines)
                return true
            }
            if !ok {
                state.withLock { $0.closed = true }
                return nil
            }
        }
    }

    /// The next line as a JSON object (skipping lines that are not one), or nil at end of stream.
    public func readObject() -> [String: Any]? {
        while let line = readLine() {
            if let object = RemoteWire.object(line) { return object }
        }
        return nil
    }

    /// Bytes already read past the last line; a channel that turns into a raw
    /// byte pipe after its opening exchange forwards these first.
    public func takeBuffered() -> Data {
        state.withLock { state in
            var data = Data()
            for line in state.queued {
                data.append(line)
                data.append(0x0A)
            }
            state.queued.removeAll()
            data.append(state.buffer.takeRemainder())
            return data
        }
    }

    /// Writes all of `data`. False once the peer is gone.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        writeLock.withLock { _ in Self.writeAll(writeDescriptor, data) }
    }

    public static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    /// Ends both directions: a blocked `readLine` on another thread returns nil.
    public func close() {
        _ = shutdown(readDescriptor, SHUT_RDWR)
        Darwin.close(readDescriptor)
        if writeDescriptor != readDescriptor { Darwin.close(writeDescriptor) }
    }

    /// The kernel's record of the connected peer (sockets only).
    public var peer: SocketPeer? { SocketPeer(descriptor: readDescriptor) }
}

/// Who is on the other end of a Unix socket, from the kernel: its uid and its
/// audit token (pid plus pid version, so a process that exec'd since does not
/// match it).
public struct SocketPeer: Sendable {
    public let uid: uid_t
    public let token: audit_token_t
    public var pid: pid_t { pid_t(bitPattern: token.val.5) }
    public var stamp: ProcessStamp? { ProcessStamp.of(pid) }

    public init?(descriptor: Int32) {
        var credentials = xucred()
        var credentialsSize = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &credentialsSize) == 0,
              credentials.cr_version == XUCRED_VERSION else { return nil }
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0 else { return nil }
        uid = credentials.cr_uid
        self.token = token
    }

    /// The peer's executable path (`proc_pidpath`), or nil.
    public var executablePath: String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Unix stream sockets at a path.
public struct LocalSocket: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case pathTooLong(String)
        case system(String, Int32)

        public var description: String {
            switch self {
            case let .pathTooLong(path): "socket path too long: \(path)"
            case let .system(call, code): "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    public init() {}

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        return address
    }

    /// Listens on `path` (any stale file there is removed), mode 0600.
    public static func listen(_ path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.system("socket", errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.system("bind", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.system("listen", code)
        }
        return descriptor
    }

    /// Connects to `path`.
    public static func connect(_ path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.system("socket", errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.system("connect", code)
        }
        return descriptor
    }

    /// Accepts connections on `listener` on a dedicated thread until it closes;
    /// each connection from a peer of this user is handed to `handle` on its own thread.
    public static func serve(_ listener: Int32, name: String, handle: @escaping @Sendable (LineChannel) -> Void) {
        let thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return
                }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                let channel = LineChannel(socket: client)
                guard let peer = channel.peer, peer.uid == geteuid() else {
                    channel.close()
                    continue
                }
                let worker = Thread { handle(channel) }
                worker.name = name + "-connection"
                worker.start()
            }
        }
        thread.name = name
        thread.start()
    }

    /// Makes `path` a directory of this user with mode 0700 (never a symlink).
    public static func makePrivateDirectory(_ path: String) -> Bool {
        if mkdir(path, 0o700) != 0, errno != EEXIST { return false }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { return false }
        return chmod(path, 0o700) == 0
    }
}
