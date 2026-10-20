import Foundation
import Testing
@testable import CmuxNextCloud

@Suite(.timeLimit(.minutes(1))) struct CloudAuthorityObservationTests {
    @Test func aCheckedReplacementKeepsObservationLiveAfterTheOldPairCloses() async throws {
        let world = CloudAuthorityObservationWorld()
        try await world.exercise { observation in
            var events = observation.events.makeAsyncIterator()
            try await observation.start()
            #expect(await events.next() == .ready)
            let old = try await world.waitForConnections(2)
            try await world.clock.waitForTimer(.seconds(250))
            await world.clock.fire(.seconds(250))
            let all = try await world.waitForConnections(4)
            for connection in old { await connection.socket.waitUntilClosed() }
            let fresh = Array(all.suffix(2))
            // Old expiry and EOF cannot retire the checked replacement.
            await world.clock.fire(.seconds(300))
            for connection in old { await connection.socket.eof() }
            let before = await world.checks
            await fresh[0].socket.emit(#"{"t":"future-owner-notice"}"#)
            try await world.waitForCheck(after: before)
            for connection in fresh { #expect(await connection.socket.closes == 0) }
            await fresh[0].socket.eof()
            #expect(await events.next() == .lost)
            #expect(await events.next() == nil)
        }
    }

    @Test func bothOwnersMustBeCheckedBeforeAdmissionOpens() async throws {
        let world = CloudAuthorityObservationWorld()
        await world.holdTeamSnapshot()
        try await world.exercise { observation in
            let listening = AsyncStream<Void>.makeStream()
            let first = Task {
                var events = observation.events.makeAsyncIterator()
                listening.continuation.yield(())
                return await events.next()
            }
            var started = listening.stream.makeAsyncIterator()
            _ = await started.next()
            do {
                try await observation.start()
                let connections = try await world.waitForConnections(2)
                let team = try #require(connections.first { $0.lease.owner == .team })
                await team.socket.eof()
                #expect(await first.value == .lost)
            } catch {
                first.cancel(); _ = await first.result
                throw error
            }
        }
    }

    @Test func stoppingDuringInitialLeaseLoadCannotOpenLateChannels() async throws {
        let world = CloudAuthorityObservationWorld()
        await world.holdNextLoad()
        try await world.exercise { observation in
            let starting = Task { try await observation.start() }
            await world.waitUntilHeld()
            await observation.stop()
            await world.release()
            await #expect(throws: CancellationError.self) { try await starting.value }
            #expect(await world.connections.isEmpty)
        }
    }

    @Test func stopFencesBeforeAHeldRenewalLoadDrains() async throws {
        let world = CloudAuthorityObservationWorld()
        try await world.exercise { observation in
            var events = observation.events.makeAsyncIterator()
            try await observation.start()
            #expect(await events.next() == .ready)
            try await world.clock.waitForTimer(.seconds(250))
            await world.holdNextLoad()
            await world.clock.fire(.seconds(250))
            await world.waitUntilHeld()
            let stopping = Task { await observation.stop() }
            #expect(await events.next() == .lost)
            await world.release()
            await stopping.value
            #expect(await world.connections.count == 2)
            for connection in await world.connections { #expect(await connection.socket.closes == 1) }
        }
    }

    @Test(arguments: [CloudAuthorityObservationWorld.Mode.missing, .duplicate, .wrongTeam])
    func invalidOwnerPairsRefuseBeforeAnyConnection(mode: CloudAuthorityObservationWorld.Mode) async throws {
        let world = CloudAuthorityObservationWorld(mode: mode)
        try await world.exercise { observation in
            var events = observation.events.makeAsyncIterator()
            await #expect(throws: CloudAuthorityWireLease.Failure.identity) { try await observation.start() }
            #expect(await events.next() == .lost)
            #expect(await world.connections.isEmpty)
        }
    }

    @Test(arguments: [CloudAuthorityObservationWorld.Mode.sameExpiry, .refuseRenewal])
    func unverifiableRenewalFencesInsteadOfReopeningOldCredentials(mode: CloudAuthorityObservationWorld.Mode) async throws {
        let world = CloudAuthorityObservationWorld(mode: mode)
        try await world.exercise { observation in
            var events = observation.events.makeAsyncIterator()
            try await observation.start()
            #expect(await events.next() == .ready)
            try await world.clock.waitForTimer(.seconds(250))
            await world.clock.fire(.seconds(250))
            #expect(await events.next() == .lost)
            #expect(await world.connections.count == 2)
        }
    }
}
