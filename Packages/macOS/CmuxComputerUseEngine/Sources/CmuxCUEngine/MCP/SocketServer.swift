// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Security

/// The engine's per-user Unix socket. The app that holds the grants serves
/// it; agents reach it through `cmux-cu-service mcp`. Only this user's
/// processes that are this same signed build connect (0700 directory, 0600
/// socket, kernel peer uid, and the peer's code checked by audit token).
public struct EngineSocket: Sendable {
    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("cmux-computer-use/engine.sock").path
    }

    public enum SocketError: Error, CustomStringConvertible {
        case system(String, Int32)
        case pathTooLong(String)
        case alreadyServing(String)

        public var description: String {
            switch self {
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            case .pathTooLong(let path): "socket path too long: \(path)"
            case .alreadyServing(let path): "another engine already serves \(path)"
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

    /// Listens and serves each accepted connection on its own task, each
    /// with its own Engine (its own element indexes) over shared services.
    /// A peer must be this user's process AND satisfy this executable's own
    /// designated code requirement: only `cmux-cu-service mcp` of this same
    /// signed build gets in, not any process that can reach the socket.
    public func serve(services: EngineServices) throws -> Never {
        // Never take the socket from an engine that is already serving it.
        if let live = connect() {
            close(live)
            throw SocketError.alreadyServing(path)
        }
        let requirement = Self.ownRequirement()
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
            if client < 0 {
                // EMFILE and friends: back off instead of spinning.
                if errno != EINTR { usleep(50_000) }
                continue
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == me,
                  Self.peer(client, satisfies: requirement) else {
                close(client)
                continue
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = MCPConnection(engine: Engine(services: services), input: client, output: client)
            Task.detached(priority: .userInitiated) {
                await connection.serve()
                close(client)
            }
        }
    }

    /// This executable's designated requirement (an ad-hoc build's is its cdhash).
    static func ownRequirement() -> SecRequirement? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The connected peer, by its audit token (not its pid, which can be
    /// reused), is valid code that satisfies `requirement`. No requirement
    /// (this build could not read its own) refuses every peer.
    static func peer(_ fd: Int32, satisfies requirement: SecRequirement?) -> Bool {
        guard let requirement else { return false }
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
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
