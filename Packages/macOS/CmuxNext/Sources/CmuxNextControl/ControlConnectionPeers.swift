import CmuxNextCompat
import Darwin

/// The process at the other end of each control connection, as its server read it
/// (`LOCAL_PEERPID` at accept), never from a request's params; one per server
/// (``ControlSocketServer/peers``). A method that must know whether an agent asks (the Credential
/// Vault, cmux issue 26412) reads it here: a caller can leave out or change its `caller` param,
/// not its own process ancestry.
public final class ControlConnectionPeers: Sendable {
    /// A connection's process and the ones that started it.
    public struct Lineage: Sendable, Equatable {
        /// It descends from this cmux (the app or a trusted cmux executable).
        public var insideCmux: Bool
        /// The executable names (last path component) from the peer up to launchd, nearest first:
        /// every process above it, past the cmux one too (a bundled cmux adapter between an agent
        /// host and the peer hides nothing).
        public var executables: [String]

        public init(insideCmux: Bool, executables: [String]) {
            self.insideCmux = insideCmux
            self.executables = executables
        }
    }

    private struct Peer {
        var pid: pid_t
        var ancestor: pid_t
        var trusted: Set<String>
        var lineage: Lineage?
    }

    private let peers = Mutex<[ControlConnectionID: Peer]>([:])
    private let ancestry: ControlPeerAncestry

    init(ancestry: ControlPeerAncestry = .system) {
        self.ancestry = ancestry
    }

    /// The server accepted `connection` from `pid`.
    func opened(_ connection: ControlConnectionID, pid: pid_t, ancestor: pid_t, trusted: Set<String>) {
        peers.withLock { $0[connection] = Peer(pid: pid, ancestor: ancestor, trusted: trusted) }
    }

    func closed(_ connection: ControlConnectionID) {
        _ = peers.withLock { $0.removeValue(forKey: connection) }
    }

    /// `connection`'s lineage, read once and kept while it is open; nil for the in-process
    /// connection and a peer whose pid the server could not read.
    public func lineage(_ connection: ControlConnectionID) -> Lineage? {
        guard let peer = peers.withLock({ $0[connection] }) else { return nil }
        if let lineage = peer.lineage { return lineage }
        let lineage = ancestry.lineage(peer.pid, ancestor: peer.ancestor, executables: peer.trusted)
        peers.withLock { $0[connection]?.lineage = lineage }
        return lineage
    }
}

extension ControlPeerAncestry {
    /// `pid`'s whole ancestry as ``ControlConnectionPeers/Lineage``; inside cmux as
    /// ``isInside(_:ancestor:executables:)`` says it, and only when the walk reached launchd (a
    /// process it could not read may have been an agent host).
    func lineage(_ pid: pid_t, ancestor: pid_t, executables trusted: Set<String>) -> ControlConnectionPeers.Lineage {
        var names: [String] = []
        var inside = false
        var current = pid
        for _ in 0..<128 {
            if current <= 1 { return .init(insideCmux: inside, executables: names) }
            guard let process = lookup(current) else { break }
            let path = process.executable
            names.append(path.map { String($0.split(separator: "/").last ?? Substring($0)) } ?? "")
            if current == ancestor || (current != pid && path.map(trusted.contains) == true) { inside = true }
            if process.parent == current || process.parent < 0 { break }
            current = process.parent
        }
        return .init(insideCmux: false, executables: names)
    }
}
