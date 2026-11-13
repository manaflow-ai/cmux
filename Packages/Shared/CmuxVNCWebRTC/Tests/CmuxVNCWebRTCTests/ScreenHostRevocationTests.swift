import CoreGraphics
import CoreVideo
@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// Stops at real signaling suspension points; no capture grant, hub service or remote machine.
@Suite(.timeLimit(.minutes(1))) struct ScreenHostRevocationTests {
    final class Gate: @unchecked Sendable {
        // @unchecked: continuation is protected by lock.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        let entered: AsyncStream<Bool>
        private let entry: AsyncStream<Bool>.Continuation
        init() { (entered, entry) = AsyncStream.makeStream(of: Bool.self) }
        func wait() async {
            await withCheckedContinuation { next in
                lock.withLock { continuation = next }
                entry.yield(true)
            }
        }
        func resume() {
            let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { continuation = nil }
                return continuation
            }
            next?.resume()
        }
    }

    final class Signaling: ScreenSignaling, Sendable {
        let input: AsyncThrowingStream<ScreenSignal, any Error>.Continuation
        private let stream: AsyncThrowingStream<ScreenSignal, any Error>
        let sent: AsyncStream<ScreenSignal>
        private let output: AsyncStream<ScreenSignal>.Continuation
        let endsSessionOnClose: Bool
        let gate: Gate?
        init(ticket: Bool = true, gate: Gate? = nil) {
            endsSessionOnClose = ticket
            self.gate = gate
            (stream, input) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, throwing: (any Error).self)
            (sent, output) = AsyncStream.makeStream(of: ScreenSignal.self)
        }
        func messages() -> AsyncThrowingStream<ScreenSignal, any Error> { stream }
        func send(_ signal: ScreenSignal) async throws { output.yield(signal) }
        func iceServers() async throws -> [ICEServerConfig] { await gate?.wait(); return [] }
        func close() { input.finish(); output.finish() }
    }

    final class Backend: ScreenBackend, @unchecked Sendable {
        // @unchecked: counters are protected by lock.
        private let lock = NSLock()
        private var starts = 0
        private var stops = 0
        var counts: (starts: Int, stops: Int) { lock.withLock { (starts, stops) } }
        func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void,
                   displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {
            lock.withLock { starts += 1 }
        }
        func select(display index: Int) {}
        func handle(_ input: ScreenInput) {}
        func stop() { lock.withLock { stops += 1 } }
    }

    final class Factory: @unchecked Sendable {
        // @unchecked: creations is protected by lock.
        private let lock = NSLock()
        private var creations = 0
        let backend = Backend()
        var count: Int { lock.withLock { creations } }
        func make() -> any ScreenBackend { lock.withLock { creations += 1 }; return backend }
    }

    @Test func ticketStoppedBeforeServeCannotDiscoverOrCreateBackend() async throws {
        let factory = Factory(), signaling = Signaling(gate: Gate())
        let host = ScreenStreamHost(name: "approved", backend: { factory.make() }, log: { _ in })
        host.disconnectViewer()
        signaling.input.yield(.offer("must never be parsed"))
        signaling.input.finish()
        try await host.serve(signaling)
        #expect(factory.count == 0)
    }

    @Test func ticketRevokedDuringICECannotInstallLateSession() async throws {
        let factory = Factory(), gate = Gate()
        let signaling = Signaling(gate: gate)
        let host = ScreenStreamHost(name: "approved", backend: { factory.make() }, log: { _ in })
        let serve = Task { try await host.serve(signaling) }
        defer { gate.resume(); serve.cancel(); signaling.close(); host.disconnectViewer() }
        signaling.input.yield(.offer("must never be parsed"))
        var entered = gate.entered.makeAsyncIterator()
        #expect(await entered.next() == true)
        // Exercise the synchronous fence alone, before off-thread connection teardown.
        host.revokeViewer()
        signaling.input.finish()
        gate.resume()
        try await serve.value
        #expect(factory.count == 0)
        let later = Signaling()
        later.input.yield(.offer("a retired ticket cannot reopen"))
        later.input.finish()
        try await host.serve(later)
        #expect(factory.count == 0)
    }

    @Test func pairingRoomAcceptsFreshOfferAfterRevokingSuspendedOffer() async throws {
        let factory = Factory(), gate = Gate()
        let pairing = VNCPairing.generate(name: "reconnect", kind: "stream")
        let host = ScreenStreamHost(pairing: pairing, backend: { factory.make() }, log: { _ in })
        let old = Signaling(ticket: false, gate: gate)
        let oldServe = Task { try await host.serve(old) }
        defer { gate.resume(); oldServe.cancel(); old.close(); host.disconnectViewer() }
        old.input.yield(.offer("stale offer"))
        var entered = gate.entered.makeAsyncIterator()
        #expect(await entered.next() == true)
        host.disconnectViewer()
        old.close()
        gate.resume()
        try await oldServe.value
        #expect(factory.count == 0)

        let viewer = try VNCPeerLink(iceServers: [], preferStreamRelays: false)
        defer { viewer.close() }
        let offer = try await viewer.offer(label: "input", receiveVideo: true)
        let fresh = Signaling(ticket: false)
        let serve = Task { try await host.serve(fresh) }
        defer { serve.cancel(); fresh.close(); host.disconnectViewer() }
        fresh.input.yield(.offer(offer))
        var signals = fresh.sent.makeAsyncIterator()
        var answered = false
        while let signal = await signals.next() {
            if case .answer = signal { answered = true; break }
        }
        #expect(answered)
        #expect(factory.count == 1)
        fresh.close()
        try await serve.value
    }

    @Test func revokeFromChannelOpenPreventsQueuedCaptureStart() async throws {
        let factory = Factory(), signaling = Signaling()
        let host = ScreenStreamHost(name: "approved", backend: { factory.make() }, log: { _ in })
        let viewer = try VNCPeerLink(iceServers: [], preferStreamRelays: false)
        let (revocations, revoked) = AsyncStream.makeStream(of: Bool.self)
        host.onEvent = { event in
            if event == .viewerConnected {
                host.revokeViewer()
                revoked.yield(true)
                revoked.finish()
            }
        }
        let serve = Task { try await host.serve(signaling) }
        let candidates = Task {
            for await event in viewer.events {
                if case let .candidate(candidate) = event {
                    signaling.input.yield(.candidate(ScreenICECandidate(candidate)))
                }
            }
        }
        let answers = Task {
            for await signal in signaling.sent {
                switch signal {
                case let .answer(sdp): try await viewer.accept(answer: sdp)
                case let .candidate(candidate): await viewer.add(candidate: candidate.message)
                default: break
                }
            }
        }
        defer {
            serve.cancel(); candidates.cancel(); answers.cancel()
            signaling.close(); host.disconnectViewer(); viewer.close(); revoked.finish()
            host.onEvent = nil
        }
        let offer = try await viewer.offer(label: "input", receiveVideo: true)
        signaling.input.yield(.offer(offer))
        var receipt = revocations.makeAsyncIterator()
        #expect(await receipt.next() == true)
        host.disconnectViewer()
        signaling.close()
        try await serve.value
        try await answers.value
        #expect(factory.count == 1)
        #expect(factory.backend.counts.starts == 0)
        #expect(factory.backend.counts.stops > 0)
    }

    #if os(macOS)
    @Test func stoppedCaptureRejectsQueuedStartBeforePermissionDiscovery() async throws {
        let backend = ScreenCaptureBackend(log: { _ in })
        backend.stop()
        do {
            try await backend.start(frame: { _, _ in Issue.record("stopped source emitted a frame") },
                                    displays: { _, _ in Issue.record("stopped source enumerated displays") })
            Issue.record("stopped source accepted start")
        } catch {
            #expect(error is CancellationError)
        }
    }
    #endif
}
