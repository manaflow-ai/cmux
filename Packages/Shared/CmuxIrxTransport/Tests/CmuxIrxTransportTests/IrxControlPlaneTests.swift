import Foundation
import Testing
import CMUXMobileCore

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
        #expect(fact.payload.bindings.count == 2)
        #expect(fact.payload.bindings[0].homeRelayURL == "https://usw1.relay.cmux.dev/")
        #expect(fact.payload.relayFleet.count == 2)
        #expect(fact.payload.grantVerificationKeys.count == 1)
        // List-auth lease stamp + per-entry authorization state.
        #expect(fact.payload.ttlSeconds == 86_400)
        #expect(fact.payload.bindings[0].revoked == false)
        #expect(fact.payload.bindings[1].status == .seeded)
        #expect(fact.payload.bindings[1].revoked == true)
    }

    /// The hand-written tolerant overlay must decode the same golden fixture
    /// the generated type does, or list-auth silently diverges from the wire.
    @Test func directoryFixtureDecodesThroughListAuthOverlay() throws {
        let fact = try Self.decoder.decode(
            IrxCtlDirectoryFact.self, from: fixture("directory"))
        #expect(fact.rev == 42)
        #expect(fact.payload.issuedAt != nil)
        #expect(fact.payload.ttlSeconds == 86_400)
        let snapshot = IrxDeviceListSnapshot(
            fact: fact, receivedAtWall: Date(), receivedAtMonotonic: .now)
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries["0fbffe130b96"]?.revoked == false)
        #expect(snapshot.entries["8de4b1c22a10"]?.status == "seeded")
        #expect(snapshot.entries["8de4b1c22a10"]?.revoked == true)
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
        private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
        private var cancelledBeforePark: Set<Int> = []
        /// Each dial's 1-based number when it starts.
        let starts = AsyncStream<Int>.makeStream()
        /// Each parked dial's number when its task is cancelled.
        let cancellations = AsyncStream<Int>.makeStream()

        func dialStarted() -> Int {
            let number = lock.withLock {
                started += 1
                return started
            }
            starts.continuation.yield(number)
            return number
        }

        var dialCount: Int { lock.withLock { started } }

        /// Parks dial `number` until its task is cancelled, then throws
        /// CancellationError. A parked dial never outlives its owner's cancel,
        /// so no test leaves a suspended task behind.
        func hold(_ number: Int) async throws {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock { () -> Bool in
                        if cancelledBeforePark.remove(number) != nil { return true }
                        parked[number] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    if let continuation = parked.removeValue(forKey: number) { return continuation }
                    cancelledBeforePark.insert(number)
                    return nil
                }
                continuation?.resume()
            }
            cancellations.continuation.yield(number)
            throw CancellationError()
        }
    }

    @Test func hintChangeCancelsInFlightDialAndRedials() async throws {
        let journal = IrxJournal(subsystem: "test", category: "hint-race", journalFileURL: nil)
        let gate = DialGate()
        let engine = IrxPeerEngine(journal: journal, label: "test") {
            // Every dial parks against the stale relay (the silent black
            // hole); the race must cancel it rather than wait it out.
            try await gate.hold(gate.dialStarted())
            throw IrxConnectionError.closed(nil)
        }
        var starts = gate.starts.stream.makeAsyncIterator()
        var cancellations = gate.cancellations.stream.makeAsyncIterator()

        await engine.warmUp(trigger: "test-warmup")
        #expect(await starts.next() == 1)

        await engine.relayHintChanged(trigger: "test-hint")
        // The race cancels dial 1 and starts dial 2 without any timer wait.
        #expect(await cancellations.next() == 1)
        #expect(await starts.next() == 2)

        // stop() cancels dial 2 too: no dial task outlives the test.
        await engine.stop()
        #expect(await cancellations.next() == 2)
        #expect(gate.dialCount == 2)
    }

    @Test func hintChangeNeverTouchesIdleEngine() async throws {
        let journal = IrxJournal(subsystem: "test", category: "hint-idle", journalFileURL: nil)
        let gate = DialGate()
        let engine = IrxPeerEngine(journal: journal, label: "test") {
            _ = gate.dialStarted()
            throw IrxConnectionError.closed(nil)
        }
        await engine.relayHintChanged(trigger: "test-idle")
        // `relayHintChanged` completes after the engine has processed the
        // event. Yield once so any incorrectly scheduled dial task gets a
        // chance to run, without introducing a timing-based assertion.
        await Task.yield()
        #expect(gate.dialCount == 0)
    }

    @Test func admissionTimeoutSchedulesAutomaticRetry() async throws {
        let journal = IrxJournal(subsystem: "test", category: "admission-timeout-retry", journalFileURL: nil)
        let gate = DialGate()
        let engine = IrxPeerEngine(
            config: .init(initialBackoff: .milliseconds(10), maxBackoff: .milliseconds(20)),
            journal: journal,
            label: "test"
        ) {
            _ = gate.dialStarted()
            throw IrxAdmissionDenied(code: .admissionTimeout)
        }

        await engine.warmUp(trigger: "test-admission-timeout")
        for _ in 0..<100 where gate.dialCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.dialCount >= 2)
        await engine.stop()
    }

    @Test func rateLimitedDialDoesNotRedialBeforeServerDeadline() async throws {
        let journal = IrxJournal(subsystem: "test", category: "retry-after", journalFileURL: nil)
        let gate = DialGate()
        let clock = PeerRetryTestClock()
        let sleeps = AsyncStream<Duration>.makeStream()
        let wake = AsyncStream<Void>.makeStream()
        let dials = AsyncStream<Void>.makeStream()
        let engine = IrxPeerEngine(
            config: .init(initialBackoff: .milliseconds(10), maxBackoff: .milliseconds(20)),
            journal: journal,
            label: "test",
            clockNow: { clock.now },
            retrySleep: { duration in
                sleeps.continuation.yield(duration)
                for await _ in wake.stream { break }
                try Task.checkCancellation()
            }
        ) {
            _ = gate.dialStarted()
            dials.continuation.yield(())
            throw CmxRateLimitedError(retryAfterSeconds: 1)
        }

        _ = try? await engine.ensureSession(trigger: "test-rate-limit")
        var dialIterator = dials.stream.makeAsyncIterator()
        _ = await dialIterator.next()
        var sleepIterator = sleeps.stream.makeAsyncIterator()
        #expect(await sleepIterator.next() == .seconds(1))
        clock.advance(by: .milliseconds(999))
        _ = try? await engine.ensureSession(trigger: "foreground-before-deadline")
        #expect(gate.dialCount == 1)
        clock.advance(by: .milliseconds(1))
        wake.continuation.yield(())
        _ = await dialIterator.next()
        #expect(gate.dialCount == 2)
        await engine.stop()
        wake.continuation.finish()
        sleeps.continuation.finish()
        dials.continuation.finish()
    }

    /// A server Retry-After near Int.max is a hostile or broken header, not a
    /// wait: the engine caps it at 2^31 s (68 years) so the deadline
    /// arithmetic and the clock's conversion cannot trap.
    @Test func retryAfterNearIntMaxWaitsTheCap() async throws {
        let journal = IrxJournal(subsystem: "test", category: "retry-after-max", journalFileURL: nil)
        let sleeps = AsyncStream<Duration>.makeStream()
        let engine = IrxPeerEngine(
            journal: journal,
            label: "test",
            retrySleep: { duration in
                sleeps.continuation.yield(duration)
                throw CancellationError()
            }
        ) {
            throw CmxRateLimitedError(retryAfterSeconds: Int.max)
        }

        _ = try? await engine.ensureSession(trigger: "test-retry-after-max")
        var sleepIterator = sleeps.stream.makeAsyncIterator()
        #expect(await sleepIterator.next() == .seconds(2_147_483_648))
        await engine.stop()
        sleeps.continuation.finish()
    }
}

private final class PeerRetryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(by duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
