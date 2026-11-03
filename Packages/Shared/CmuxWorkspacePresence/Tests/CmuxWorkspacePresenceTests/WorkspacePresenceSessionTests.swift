import CMUXMobileCore
import CmuxWorkspacePresence
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) @MainActor
struct WorkspacePresenceSessionTests {
    private final class Credentials { var attempts = 0 }

    @Test("a transient credential failure reconnects without detaching the row")
    func retriesTokenRefresh() async throws {
        let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: "one", teamID: "team"))
        let transport = PresenceTestTransport()
        let session = WorkspacePresenceSession(transport: transport)
        let credentials = Credentials()
        let run = Task {
            await session.run(scope: scope, accessToken: {
                credentials.attempts += 1
                return credentials.attempts == 1 ? nil : "test"
            }, isCurrent: { true })
        }
        defer { run.cancel(); session.stop() }
        let opened = try #require(await PresenceTestTransport.next(transport.connections))
        #expect(opened.scope == scope)
        #expect(credentials.attempts == 2)
    }

    @Test("a disconnected viewer disappears from the same stream used by sidebar rows")
    func disconnectPublishesEmptyRoster() async throws {
        let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: "one", teamID: "team"))
        let transport = PresenceTestTransport()
        let session = WorkspacePresenceSession(transport: transport)
        let snapshots = session.snapshots()
        let run = Task { await session.run(scope: scope, accessToken: { "test" }, isCurrent: { true }) }
        defer { run.cancel(); session.stop() }
        let opened = try #require(await PresenceTestTransport.next(transport.connections))
        let ada = WorkspacePresenceParticipant(id: "ada", displayName: "Ada")
        await opened.connection.deliver(WorkspacePresenceSnapshot(scope: scope, participants: [ada]))
        #expect(await PresenceTestTransport.next(snapshots, matching: { !$0.isEmpty }) == [ada])
        await opened.connection.disconnect()
        #expect(await PresenceTestTransport.next(snapshots) == [])
    }

    @Test("an invalid snapshot closes the session-owned socket before reconnecting")
    func invalidSnapshotClosesSessionOwnedSocketBeforeReconnect() async throws {
        let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: "one", teamID: "team"))
        let transport = PresenceTestTransport()
        let session = WorkspacePresenceSession(transport: transport, clock: ImmediatePresenceClock())
        let run = Task { await session.run(scope: scope, accessToken: { "test" }, isCurrent: { true }) }
        defer { run.cancel(); session.stop() }

        let firstOpened = try #require(await PresenceTestTransport.next(transport.connections))
        let invalidScope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: "other", teamID: "team"))
        await firstOpened.connection.deliver(WorkspacePresenceSnapshot(scope: invalidScope, participants: []))

        let secondOpened = try #require(await PresenceTestTransport.next(transport.connections))
        #expect(secondOpened.scope == scope)
        await firstOpened.connection.waitUntilEnded()
        #expect(await firstOpened.connection.isEnded)
    }

    @Test("a valid snapshot resets the next reconnect delay")
    func snapshotResetsReconnectDelay() async throws {
        let scope = try #require(WorkspacePresenceScope(kind: .cloud, ownerID: "vm", workspaceID: "one", teamID: "team"))
        let transport = PresenceTestTransport()
        let clock = ImmediatePresenceClock()
        let session = WorkspacePresenceSession(transport: transport, clock: clock)
        let snapshots = session.snapshots()
        let run = Task { await session.run(scope: scope, accessToken: { "test" }, isCurrent: { true }) }
        defer { run.cancel(); session.stop() }

        let first = try #require(await PresenceTestTransport.next(transport.connections))
        await first.connection.disconnect()
        let second = try #require(await PresenceTestTransport.next(transport.connections))
        let ada = WorkspacePresenceParticipant(id: "ada", displayName: "Ada")
        await second.connection.deliver(WorkspacePresenceSnapshot(scope: scope, participants: [ada]))
        #expect(await PresenceTestTransport.next(snapshots, matching: { $0 == [ada] }) == [ada])
        await second.connection.disconnect()

        _ = try #require(await PresenceTestTransport.next(transport.connections))
        #expect(Array(clock.reconnectBackoffMarkers.prefix(2)) == [1, 1])
    }
}

private final class ImmediatePresenceClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration
    typealias Instant = ContinuousClock.Instant

    private let lock = NSLock()
    private var recordedSleeps: [Duration] = []
    private let origin: Instant = .now

    nonisolated var now: Instant { origin }
    nonisolated var minimumResolution: Duration { .zero }

    var reconnectBackoffMarkers: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps.filter { $0 < .seconds(5) }.map { $0 < .milliseconds(1500) ? 1 : 2 }
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let duration = now.duration(to: deadline)
        lock.withLock { recordedSleeps.append(duration) }
        guard duration >= .seconds(5) else { return }
        try await ContinuousClock().sleep(for: .seconds(3600))
    }
}
