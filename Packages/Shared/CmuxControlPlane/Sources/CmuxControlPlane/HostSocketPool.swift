import CmuxMobileWire

/// One HostDO control socket per Mac (`/v1/wire/host/<host>[?team=]`),
/// shared by every feature that talks to that Mac: workspaces (C5), tasks
/// (C8), presence (B6) and WebRTC signaling (D1). `HostDO` keeps one live
/// socket per role and identity and closes the older one (4000) when the same
/// install connects again, so separate sockets per feature replaced each
/// other. The pool hands out leases; the first lease's `start()` connects,
/// the last lease's `stop()` closes the socket.
public actor HostSocketPool {
    public typealias MakeClient = @Sendable (_ host: String, _ team: String?) async throws -> ControlPlaneClient

    private struct Key: Hashable {
        var host: String
        var team: String?
    }

    private let makeClient: MakeClient
    private var sockets: [Key: (socket: SharedHostSocket, leases: Int)] = [:]

    /// - Parameter makeClient: builds the socket's client (URL with `team=`
    ///   for another account's Mac, `hello` as this install, token provider).
    public init(makeClient: @escaping MakeClient) {
        self.makeClient = makeClient
    }

    /// A lease on `host`'s socket. `team` names the Mac's team when it is
    /// another account's (B6 guest admission); nil or empty for own Macs.
    public func session(host: String, team: String? = nil) -> any ControlPlaneSession {
        let key = Key(host: host, team: team?.isEmpty == false ? team : nil)
        let socket: SharedHostSocket
        if let entry = sockets[key] {
            socket = entry.socket
            sockets[key]?.leases += 1
        } else {
            let make = makeClient
            socket = SharedHostSocket { try await make(key.host, key.team) }
            sockets[key] = (socket, 1)
        }
        return HostSocketLease(socket: socket) { [weak self] in await self?.release(key, socket) }
    }

    /// Hosts with an open socket (diagnostics, tests).
    public var openHosts: [String] { sockets.keys.map(\.host).sorted() }

    /// Closes every socket (sign-out, account switch); live leases end.
    public func stopAll() async {
        let all = sockets.values.map(\.socket)
        sockets.removeAll()
        for socket in all { await socket.shutdown() }
    }

    private func release(_ key: Key, _ socket: SharedHostSocket) async {
        guard let entry = sockets[key], entry.socket === socket else { return }
        if entry.leases > 1 {
            sockets[key]?.leases -= 1
            return
        }
        sockets[key] = nil
        await socket.shutdown()
    }
}
