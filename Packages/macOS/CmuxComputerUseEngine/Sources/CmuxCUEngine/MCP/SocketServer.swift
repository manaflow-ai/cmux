// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The engine's per-user Unix socket. The app that holds the grants serves
/// it; agents reach it through `cmux-cu-mcp`. Only processes of the same
/// user connect (0700 directory, 0600 socket, kernel peer uid checked).
public struct EngineSocket: Sendable {
    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("cmux-computer-use/engine.sock").path
    }

    public enum SocketError: Error, CustomStringConvertible {
        case system(String, Int32)
        case pathTooLong(String)

        public var description: String {
            switch self {
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            case .pathTooLong(let path): "socket path too long: \(path)"
            }
        }
    }

    public let path: String
    public init(path: String = EngineSocket.defaultPath) { self.path = path }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Listens and serves each accepted connection on its own task.
    public func serve(engine: Engine) throws -> Never {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(directory, 0o700)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var address = try Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw SocketError.system("bind", errno) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw SocketError.system("listen", errno) }
        let me = geteuid()
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == me else {
                close(client)
                continue
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
            let connection = MCPConnection(engine: engine, input: handle, output: handle)
            Task.detached(priority: .userInitiated) { await connection.serve() }
        }
    }

    /// Connects as a client; nil when nothing listens.
    public func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = try? Self.address(path) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}
