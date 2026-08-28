import CryptoKit
import Foundation
import Testing

@testable import CmuxDotTransport

/// Wires an initiator and a responder session back to back: each session's
/// transmit feeds the other's inbound handler, exactly as two legs joined by
/// a lossless relay would.
enum MuxRig {
    struct Pair {
        let phone: DotMuxSession
        let mac: DotMuxSession
    }

    static func makePair() async throws -> Pair {
        let rig = DotHandshakeTests.Rig()
        let initiator = try await DotHandshakeInitiator.make(
            identity: rig.phone, grantJWS: try rig.grant())
        let outcome = try await DotHandshakeResponder.respond(
            hs1Payload: initiator.hs1Payload,
            identity: rig.mac,
            admission: rig.admission,
            judge: { _ in }
        )
        let initiated = try initiator.processHs2(
            outcome.hs2Payload, expectedPeerPublicKey: rig.mac.publicKey)

        let phoneInbox = Inbox()
        let macInbox = Inbox()
        let phone = DotMuxSession(
            role: .initiator,
            keys: initiated.keys,
            peer: DotAdmittedPeer(
                identityPublicKey: rig.mac.publicKey, deviceID: "mac",
                platform: "mac", tag: nil, bindingID: nil, grantJTI: nil),
            sessionID: initiated.sessionID,
            journal: .discarding,
            transmit: { data in await macInbox.deliver(data) },
            onEnd: { _ in }
        )
        let mac = DotMuxSession(
            role: .responder,
            keys: outcome.keys,
            peer: outcome.peer,
            sessionID: outcome.sessionID,
            journal: .discarding,
            transmit: { data in await phoneInbox.deliver(data) },
            onEnd: { _ in }
        )
        await phoneInbox.bind(to: phone)
        await macInbox.bind(to: mac)
        await phone.begin()
        await mac.begin()
        try await phone.waitAdmitted()
        return Pair(phone: phone, mac: mac)
    }

    /// Buffers sealed frames until the destination session exists, then
    /// forwards in order (transmit closures are created before the peer).
    actor Inbox {
        private var target: DotMuxSession?
        private var pending: [Data] = []

        func bind(to session: DotMuxSession) async {
            target = session
            let queued = pending
            pending = []
            for frame in queued {
                await session.handleInboundSealed(frame)
            }
        }

        func deliver(_ frame: Data) async {
            if let target {
                await target.handleInboundSealed(frame)
            } else {
                pending.append(frame)
            }
        }
    }
}

@Suite("mux session")
struct DotMuxSessionTests {
    @Test func controlStreamRoundtrip() async throws {
        let pair = try await MuxRig.makePair()
        let macEvents = pair.mac.events

        let control = try await pair.phone.openStream(.control)
        try await control.write(Data("ping-from-phone".utf8))

        var inbound: (any DotStream)?
        for await event in macEvents {
            if case .inboundStream(let stream) = event {
                inbound = stream
                break
            }
        }
        let macControl = try #require(inbound)
        #expect(macControl.descriptor.lane == "control")
        #expect(try await macControl.read() == Data("ping-from-phone".utf8))

        try await macControl.write(Data("pong-from-mac".utf8))
        #expect(try await control.read() == Data("pong-from-mac".utf8))
    }

    @Test func largeWritesChunkAndReassemble() async throws {
        let pair = try await MuxRig.makePair()
        let macEvents = pair.mac.events

        let lane = try await pair.phone.openStream(
            .terminal(resource: "terminal:abc", cursor: 5))
        var payload = Data(repeating: 0xAB, count: 300 * 1024)
        payload[0] = 0x01
        payload[payload.count - 1] = 0x02
        try await lane.write(payload)
        await lane.closeWrite()

        var inbound: (any DotStream)?
        for await event in macEvents {
            if case .inboundStream(let stream) = event {
                inbound = stream
                break
            }
        }
        let macLane = try #require(inbound)
        #expect(macLane.descriptor.lane == "terminal")
        #expect(macLane.descriptor.resource == "terminal:abc")
        #expect(macLane.descriptor.cursor == 5)

        var received = Data()
        var chunks = 0
        while let chunk = try await macLane.read() {
            received.append(chunk)
            chunks += 1
        }
        // 300 KiB at a 128 KiB cap = 3 chunks, boundaries invisible to bytes.
        #expect(chunks == 3)
        #expect(received == payload)
    }

    @Test func hostOpensEventsLane() async throws {
        let pair = try await MuxRig.makePair()
        let phoneEvents = pair.phone.events

        let events = try await pair.mac.openStream(.events)
        try await events.write(Data("server-event".utf8))

        var inbound: (any DotStream)?
        for await event in phoneEvents {
            if case .inboundStream(let stream) = event {
                inbound = stream
                break
            }
        }
        let phoneLane = try #require(inbound)
        #expect(phoneLane.descriptor.lane == "events")
        #expect(try await phoneLane.read() == Data("server-event".utf8))
    }

    @Test func goawayEndsBothSides() async throws {
        let pair = try await MuxRig.makePair()
        let macEvents = pair.mac.events
        let control = try await pair.phone.openStream(.control)
        _ = control

        await pair.phone.close(reason: "test-close")
        var endedReason: String?
        for await event in macEvents {
            if case .ended(let reason) = event {
                endedReason = reason
                break
            }
        }
        #expect(endedReason?.contains("test-close") == true)
        #expect(await pair.mac.isEnded)
        #expect(await pair.phone.isEnded)
    }

    @Test func failWakesBlockedReaders() async throws {
        let pair = try await MuxRig.makePair()
        let control = try await pair.phone.openStream(.control)
        let reader = Task {
            try await control.read()
        }
        // Give the reader a beat to park, then kill the session under it.
        try await Task.sleep(for: .milliseconds(50))
        await pair.phone.fail(reason: "leg-reset: test")
        await #expect(throws: DotMuxError.self) {
            _ = try await reader.value
        }
    }

    @Test func waitAdmittedUnparksOnCancellation() async throws {
        let rig = DotHandshakeTests.Rig()
        let initiator = try await DotHandshakeInitiator.make(
            identity: rig.phone, grantJWS: try rig.grant())
        let outcome = try await DotHandshakeResponder.respond(
            hs1Payload: initiator.hs1Payload,
            identity: rig.mac,
            admission: rig.admission,
            judge: { _ in }
        )
        let initiated = try initiator.processHs2(
            outcome.hs2Payload, expectedPeerPublicKey: rig.mac.publicKey)
        // Initiator session whose admit never arrives (transmit to nowhere).
        let orphan = DotMuxSession(
            role: .initiator,
            keys: initiated.keys,
            peer: outcome.peer,
            sessionID: initiated.sessionID,
            journal: .discarding,
            transmit: { _ in },
            onEnd: { _ in }
        )
        await orphan.begin()
        // The deadline group must be able to exit even though no admit or
        // session end will ever resume the waiter.
        await #expect(throws: (any Error).self) {
            try await withDeadline(seconds: 0.2) {
                try await orphan.waitAdmitted()
            }
        }
    }

    @Test func finDeliversBufferedDataBeforeEOF() async throws {
        let pair = try await MuxRig.makePair()
        let macEvents = pair.mac.events
        let lane = try await pair.phone.openStream(.events)
        try await lane.write(Data("tail".utf8))
        await lane.closeWrite()

        var inbound: (any DotStream)?
        for await event in macEvents {
            if case .inboundStream(let stream) = event {
                inbound = stream
                break
            }
        }
        let macLane = try #require(inbound)
        #expect(try await macLane.read() == Data("tail".utf8))
        #expect(try await macLane.read() == nil)
    }
}
