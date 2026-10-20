import Foundation
@testable import CmuxNextCloud

actor CloudAuthorityObservationWorld {
    enum Mode: Sendable, Equatable { case valid, missing, duplicate, wrongTeam, sameExpiry, refuseRenewal }
    struct Connection: Sendable {
        let lease: CloudAuthorityWireLease
        let socket: CloudAuthorityWireTestSocket
    }
    let clock = CloudAuthorityWireTestClock()
    private let mode: Mode
    private let connected = AsyncStream<Int>.makeStream()
    private let checked = AsyncStream<Int>.makeStream()
    private let held = AsyncStream<Void>.makeStream()
    private var hold: CheckedContinuation<Void, Never>?
    private var shouldHold = false
    private var holdTeam = false
    private(set) var loads = 0
    private(set) var checks = 0
    private(set) var connections: [Connection] = []

    init(mode: Mode = .valid) { self.mode = mode }
    func holdNextLoad() { shouldHold = true }
    func holdTeamSnapshot() { holdTeam = true }
    func release() { hold?.resume(); hold = nil }
    func waitUntilHeld() async { var iterator = held.stream.makeAsyncIterator(); _ = await iterator.next() }

    func leases() async throws -> [CloudAuthorityWireLease] {
        loads += 1
        let generation = loads
        if shouldHold {
            shouldHold = false
            // Models a bounded HTTP load that has not returned when its caller is cancelled.
            await withCheckedContinuation { hold = $0; held.continuation.yield(()) }
        }
        if generation > 1, mode == .refuseRenewal { throw CloudTeamScope.Failure.changed }
        let expiry: Double = generation == 1 || mode == .sameExpiry ? 1_300 : 1_500
        let user = try CloudAuthorityWireWorld.lease(owner: .user, expiry: expiry)
        let team = try CloudAuthorityWireWorld.lease(owner: .team, expiry: expiry)
        if mode == .missing { return [user] }
        if mode == .duplicate { return [user, user] }
        return [user, team]
    }

    func check() { checks += 1; checked.continuation.yield(checks) }
    func waitForCheck(after count: Int) async throws {
        var iterator = checked.stream.makeAsyncIterator()
        while let next = await iterator.next() { if next > count { return } }
        throw CancellationError()
    }

    func connect(_ lease: CloudAuthorityWireLease) async -> any CloudAuthorityWireSocket {
        let socket = CloudAuthorityWireTestSocket()
        connections.append(Connection(lease: lease, socket: socket))
        connected.continuation.yield(connections.count)
        await socket.emit(CloudAuthorityWireWorld.welcome(owner: lease.owner))
        if lease.owner == .user { await socket.emit(CloudAuthorityWireWorld.userSnapshot) }
        else if !holdTeam { await socket.emit(CloudAuthorityWireWorld.snapshot) }
        return socket
    }

    func waitForConnections(_ count: Int) async throws -> [Connection] {
        var iterator = connected.stream.makeAsyncIterator()
        while connections.count < count {
            guard await iterator.next() != nil else { throw CancellationError() }
        }
        return Array(connections.prefix(count))
    }

    func makeObservation() -> CloudAuthorityObservation {
        let clock = clock
        return CloudAuthorityObservation(scopeID: "scope-original", team: mode == .wrongTeam ? "other" : "team_1",
            leases: { try await self.leases() }, recheck: { await self.check() }, connect: { await self.connect($0) },
            now: { CloudAuthorityWireWorld.now }, sleep: { try await clock.sleep($0) })
    }

    func exercise(_ body: @Sendable (CloudAuthorityObservation) async throws -> Void) async throws {
        let observation = makeObservation()
        do {
            try await body(observation)
            release(); await observation.stop(); await clock.finish()
        } catch {
            release(); await observation.stop(); await clock.finish()
            throw error
        }
    }
}
