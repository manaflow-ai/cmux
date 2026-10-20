import Foundation
@testable import CmuxNextCloud

/// Uses the real scoped lease producer and owner checks with injected socket I/O and expiry deadlines.
actor CloudAuthoritySessionTestWire {
    struct Connection: Sendable {
        let lease: CloudAuthorityWireLease
        let socket: CloudAuthorityWireTestSocket
    }
    let clock = CloudAuthorityWireTestClock()
    private let connected = AsyncStream<Int>.makeStream()
    private var holdTeam = false
    private(set) var connections: [Connection] = []

    func holdTeamSnapshots() { holdTeam = true }
    func releaseTeamSnapshots() async throws {
        holdTeam = false
        for connection in connections where connection.lease.owner == .team {
            await connection.socket.emit(try snapshot(connection.lease))
        }
    }
    func connect(_ lease: CloudAuthorityWireLease) async throws -> any CloudAuthorityWireSocket {
        let socket = CloudAuthorityWireTestSocket()
        connections.append(Connection(lease: lease, socket: socket))
        await socket.emit(try JSONSerialization.data(withJSONObject: ["t": "welcome",
            "principal": ["user": lease.user, "team": lease.team, "install": lease.install], "streams": [lease.stream]]))
        if lease.owner != .team || !holdTeam { await socket.emit(try snapshot(lease)) }
        connected.continuation.yield(connections.count)
        return socket
    }
    private func snapshot(_ lease: CloudAuthorityWireLease) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["t": "snapshot", "stream": lease.stream, "seq": 0])
    }
    func waitForConnections(_ count: Int) async throws {
        var iterator = connected.stream.makeAsyncIterator()
        while connections.count < count { guard await iterator.next() != nil else { throw CancellationError() } }
    }
    func latest(_ owner: CloudAuthorityWireLease.Owner) throws -> Connection {
        guard let connection = connections.last(where: { $0.lease.owner == owner }) else { throw CancellationError() }
        return connection
    }
    func event(_ owner: CloudAuthorityWireLease.Owner = .team) async throws {
        let connection = try latest(owner)
        await connection.socket.emit(try JSONSerialization.data(withJSONObject: ["t": "event", "stream": connection.lease.stream, "seq": 1]))
    }
    nonisolated func make(_ scope: CloudTeamScope.Snapshot) -> CloudAuthorityObservation {
        CloudAuthorityObservation(scopeID: scope.id, team: scope.team, leases: scope.wireLeases, recheck: scope.recheck,
            connect: { try await self.connect($0) }, sleep: { try await self.clock.sleep($0) })
    }
}
