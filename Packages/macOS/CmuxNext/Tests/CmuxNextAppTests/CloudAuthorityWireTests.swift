import Foundation
import Testing
@testable import CmuxNextCloud

@Suite(.timeLimit(.minutes(1))) struct CloudAuthorityWireTests {
    @Test func subscriptionIsReadyOnlyAfterTheOriginalAuthorityCheck() async throws {
        let world = CloudAuthorityWireWorld()
        await world.holdNextCheck()
        try await world.exercise { wire in
            await world.socket.emit(CloudAuthorityWireWorld.welcome())
            let sent = await world.socket.nextSent()
            #expect(sent == Data(#"{"t":"subscribe","pending":[]}"#.utf8))
            await world.socket.emit(CloudAuthorityWireWorld.snapshot)
            await world.waitUntilHeld()
            await world.release()
            var events = wire.events.makeAsyncIterator()
            #expect(await events.next() == .ready)
        }
        #expect(await world.socket.closes == 1)
    }

    @Test func anIdleMembershipEventRechecksAndRetiresTheOriginalAuthority() async throws {
        let world = CloudAuthorityWireWorld()
        try await world.exercise { wire in
            var events = wire.events.makeAsyncIterator()
            await world.socket.emit(CloudAuthorityWireWorld.welcome())
            await world.socket.emit(CloudAuthorityWireWorld.snapshot)
            #expect(await events.next() == .ready)
            await world.changeAuthority()
            await world.socket.emit(#"{"t":"event","stream":"team:team_1","seq":1,"op":"team.member.provision"}"#)
            #expect(await events.next() == .lost)
            #expect(await events.next() == nil)
        }
        #expect(await world.checks == 2)
    }

    @Test func streamLossFencesBeforeAHeldHTTPCheckDrainsAndCannotPublishLateReady() async throws {
        let world = CloudAuthorityWireWorld()
        await world.holdNextCheck()
        try await world.exercise { wire in
            var events = wire.events.makeAsyncIterator()
            await world.socket.emit(CloudAuthorityWireWorld.welcome())
            await world.socket.emit(CloudAuthorityWireWorld.snapshot)
            await world.waitUntilHeld()
            await world.socket.eof()
            #expect(await events.next() == .lost)
            // The test has not released HTTP yet: loss cannot wait for that read.
            await world.release()
            #expect(await events.next() == nil)
        }
    }

    @Test(arguments: ["wrong-user", "wrong-stream", "event-before-snapshot", "malformed", "oversize"])
    func unverifiableFramesNeverOpenAdmission(mode: String) async throws {
        let world = CloudAuthorityWireWorld()
        try await world.exercise { wire in
            var events = wire.events.makeAsyncIterator()
            if mode == "wrong-user" { await world.socket.emit(CloudAuthorityWireWorld.welcome(user: "other")) }
            else {
                await world.socket.emit(CloudAuthorityWireWorld.welcome())
                switch mode {
                case "wrong-stream": await world.socket.emit(#"{"t":"snapshot","stream":"team:other","seq":0}"#)
                case "event-before-snapshot": await world.socket.emit(#"{"t":"event","stream":"team:team_1","seq":1}"#)
                case "oversize": await world.socket.emit(Data(repeating: 32, count: (8 << 20) + 1))
                default: await world.socket.emit("not JSON")
                }
            }
            #expect(await events.next() == .lost)
            #expect(await events.next() == nil)
        }
        #expect(await world.checks == 0)
    }

    @Test func aQuietExpiredLeaseClosesWithoutWaitingForAnOwnerEvent() async throws {
        let world = CloudAuthorityWireWorld()
        try await world.exercise { wire in
            var events = wire.events.makeAsyncIterator()
            await world.socket.emit(CloudAuthorityWireWorld.welcome())
            await world.socket.emit(CloudAuthorityWireWorld.snapshot)
            #expect(await events.next() == .ready)
            let first = await world.clock.nextTimer(), second = await world.clock.nextTimer()
            #expect(Set([first, second].compactMap { $0 }) == Set([.seconds(15), .seconds(300)]))
            await world.clock.fire(.seconds(300))
            #expect(await events.next() == .lost)
        }
        #expect(await world.socket.closes == 1)
    }

    @Test func anUnansweredSubscriptionHasABoundedHandshakeDeadline() async throws {
        let world = CloudAuthorityWireWorld()
        try await world.exercise { wire in
            var events = wire.events.makeAsyncIterator()
            _ = await world.clock.nextTimer(); _ = await world.clock.nextTimer()
            await world.clock.fire(.seconds(15))
            #expect(await events.next() == .lost)
        }
        #expect(await world.checks == 0)
    }

    @Test func unknownEphemeralFramesAreAuthorityWakeups() async throws {
        let world = CloudAuthorityWireWorld()
        try await world.exercise { wire in
            var events = wire.events.makeAsyncIterator()
            await world.socket.emit(CloudAuthorityWireWorld.welcome())
            await world.socket.emit(CloudAuthorityWireWorld.snapshot)
            #expect(await events.next() == .ready)
            _ = await world.nextCheck()
            await world.socket.emit(#"{"t":"future-owner-notice"}"#)
            #expect(await world.nextCheck() == 2)
            await world.socket.eof()
            #expect(await events.next() == .lost)
        }
    }

    @Test(arguments: ["iss", "aud", "sub", "inst", "team", "agt"])
    func credentialsCannotChangeTheOriginalInstallOrTeam(claim: String) async {
        #expect(throws: (any Error).self) { try CloudAuthorityWireWorld.lease(changes: [claim: "other"]) }
    }

    @Test func transportKeepsBearersOutOfURLsAndSubprotocols() throws {
        let lease = try CloudAuthorityWireWorld.lease()
        let transport = CloudAuthorityWireTransport(origin: try #require(URL(string: "https://api.test")), headers: ["x-cmux-client-version": "2.4.0"])
        let request = try transport.request(lease)
        #expect(request.url?.absoluteString == "wss://api.test/v1/wire/team")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + lease.token)
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1, team.team_1")
        #expect(request.value(forHTTPHeaderField: "x-cmux-client-version") == "2.4.0")
    }

    @Test func userObservationHasNoTeamSelectorAndStillChecksTheOriginalInstall() async throws {
        let lease = try CloudAuthorityWireWorld.lease(owner: .user)
        let transport = CloudAuthorityWireTransport(origin: try #require(URL(string: "https://api.test")), headers: [:])
        let request = try transport.request(lease)
        #expect(request.url?.absoluteString == "wss://api.test/v1/wire/user")
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1")
        let world = CloudAuthorityWireWorld()
        try await world.exercise(owner: .user) { wire in
            var events = wire.events.makeAsyncIterator()
            await world.socket.emit(CloudAuthorityWireWorld.welcome(owner: .user))
            await world.socket.emit(CloudAuthorityWireWorld.userSnapshot)
            #expect(await events.next() == .ready)
            await world.socket.eof()
            #expect(await events.next() == .lost)
        }
    }

    @Test func expiredCredentialsAndHeaderOverridesCannotStartAConnection() throws {
        #expect(throws: (any Error).self) { try CloudAuthorityWireWorld.lease(expiry: 999) }
        let transport = CloudAuthorityWireTransport(origin: try #require(URL(string: "https://api.test")), headers: ["Authorization": "other"])
        #expect(throws: (any Error).self) { try transport.request(CloudAuthorityWireWorld.lease()) }
    }

    @Test(arguments: ["http://api.test", "https://user:password@api.test", "https://api.test/?token=secret", "https://api.test/path", "https://api.test/#fragment"])
    func noncanonicalOrUnprotectedOriginsAreRefused(origin: String) throws {
        let transport = CloudAuthorityWireTransport(origin: try #require(URL(string: origin)), headers: [:])
        #expect(throws: (any Error).self) { try transport.request(CloudAuthorityWireWorld.lease()) }
    }
}
