import Foundation
import Testing

@testable import CmuxIrxTransport

/// Golden-fixture contract tests: every checked-in control-plane fixture must
/// decode into the generated wire types. The worker's test suite decodes the
/// SAME files into the generated TypeScript types, so the two platforms can
/// only drift by failing one of these suites.
@Suite struct IrxControlPlaneWireTests {
    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // IrxControlPlaneTests.swift
        .deletingLastPathComponent()  // CmuxIrxTransportTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // CmuxIrxTransport
        .deletingLastPathComponent()  // Shared
        .deletingLastPathComponent()  // Packages
        .appendingPathComponent("schemas/control-plane/fixtures")

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = iso.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unparseable date: \(raw)"))
            }
            return date
        }
        return decoder
    }()

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesDirectory.appendingPathComponent("\(name).json"))
    }

    @Test func relayPassesFixtureDecodes() throws {
        let fact = try Self.decoder.decode(CTLRelayPasses.self, from: fixture("relay-passes"))
        #expect(fact.v == 1)
        #expect(fact.rev == 42)
        #expect(fact.payload.endpointID == "0fbffe130b96")
        #expect(fact.payload.passes.count == 1)
        #expect(fact.payload.passes[0].relayURL == "https://usw1.relay.cmux.dev/")
        #expect(fact.payload.passes[0].expiresAt > fact.payload.passes[0].refreshAfter)
    }

    @Test func directoryFixtureDecodes() throws {
        let fact = try Self.decoder.decode(CTLDirectory.self, from: fixture("directory"))
        #expect(fact.payload.bindings.count == 1)
        #expect(fact.payload.bindings[0].homeRelayURL == "https://usw1.relay.cmux.dev/")
        #expect(fact.payload.relayFleet.count == 2)
        #expect(fact.payload.grantVerificationKeys.count == 1)
    }

    @Test func hintUpdateFixtureDecodes() throws {
        let fact = try Self.decoder.decode(CTLHintUpdate.self, from: fixture("hint-update"))
        #expect(fact.payload.homeRelayURL == "https://use4.relay.cmux.dev/")
    }

    @Test func controlFrameFixturesDecode() throws {
        _ = try Self.decoder.decode(CTLHelloACK.self, from: fixture("hello-ack"))
        _ = try Self.decoder.decode(CTLSnapshotComplete.self, from: fixture("snapshot-complete"))
        _ = try Self.decoder.decode(CTLError.self, from: fixture("control-error"))
        _ = try Self.decoder.decode(CTLHello.self, from: fixture("hello"))
        _ = try Self.decoder.decode(CTLMintRequest.self, from: fixture("mint-request"))
        _ = try Self.decoder.decode(CTLPublishHint.self, from: fixture("publish-hint"))
    }

    /// Round-trip: encoding what we decoded re-parses identically, so the
    /// client can never emit a frame the schema disallows structurally.
    @Test func helloRoundTrips() throws {
        let hello = try Self.decoder.decode(CTLHello.self, from: fixture("hello"))
        let encoded = try JSONEncoder().encode(hello)
        let again = try Self.decoder.decode(CTLHello.self, from: encoded)
        #expect(hello == again)
    }
}

/// The event-driven relay race on the reconnect owner.
@Suite struct IrxPeerEngineHintRaceTests {
    private final class DialGate: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var release: [CheckedContinuation<Void, Never>] = []

        func dialStarted() { lock.lock(); started += 1; lock.unlock() }
        var dialCount: Int { lock.lock(); defer { lock.unlock() }; return started }
        func hold() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                release.append(continuation)
                lock.unlock()
            }
        }
        func releaseAll() {
            lock.lock()
            let pending = release
            release = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    @Test func hintChangeCancelsInFlightDialAndRedials() async throws {
        let journal = IrxJournal(subsystem: "test", category: "hint-race", journalFileURL: nil)
        let gate = DialGate()
        let engine = IrxPeerEngine(journal: journal, label: "test") {
            gate.dialStarted()
            // First dial parks forever against the stale relay (the silent
            // black hole); the race must cancel it rather than wait it out.
            await gate.hold()
            throw IrxConnectionError.closed(nil)
        }
        await engine.warmUp(trigger: "test-warmup")
        // Wait until the first dial is actually in flight.
        for _ in 0..<100 where gate.dialCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.dialCount == 1)

        await engine.relayHintChanged(trigger: "test-hint")
        // The race cancels dial 1 and starts dial 2 without any timer wait.
        for _ in 0..<100 where gate.dialCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.dialCount == 2)
        gate.releaseAll()
    }

    @Test func hintChangeNeverTouchesIdleEngine() async throws {
        let journal = IrxJournal(subsystem: "test", category: "hint-idle", journalFileURL: nil)
        let gate = DialGate()
        let engine = IrxPeerEngine(journal: journal, label: "test") {
            gate.dialStarted()
            throw IrxConnectionError.closed(nil)
        }
        await engine.relayHintChanged(trigger: "test-idle")
        try await Task.sleep(for: .milliseconds(50))
        #expect(gate.dialCount == 0)
    }
}
