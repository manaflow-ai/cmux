import CmuxLink
import Foundation
import os

extension LinkConformanceSuite {
    /// `rawBackPressure`: the host floods a reliable bulk lane of a bare
    /// transport while the dialer reads nothing. The host's `send` must stop
    /// being accepted within `rawBufferLimitBytes` (the sender is slowed, no
    /// side buffers without bound); after the dialer reads, every frame
    /// arrives once and in order.
    func rawBackPressure(deadline: Deadline) async throws -> ConformanceOutcome {
        let name = harness.name
        let fail: @Sendable (String) -> ConformanceFailure = { message in
            ConformanceFailure(harness: name, testCase: .rawBackPressure, message: message)
        }
        let endpoints = try await harness.makeEndpoints()
        guard let carrier = endpoints.carriers.first else { throw fail("no carrier") }
        let incoming = endpoints.acceptor.incoming
        let accepted = Task { () -> (any LinkTransport)? in
            for await transport in incoming { return transport }
            return nil
        }
        let dialed = try await deadline.run("dial") { try await carrier.connect(to: endpoints.peer) }
        guard let host = try await deadline.run("accept", { await accepted.value }) else {
            await dialed.close()
            throw fail("acceptor ended")
        }
        let frameBytes = min(64 << 10, host.capabilities.maxFrameBytes, dialed.capabilities.maxFrameBytes)
        let sendLimit = max(rawBufferLimitBytes * 3, 64 << 20)
        let lane = TransportLane(reliability: .reliableOrdered, priority: .bulk)
        let progress = RawSendProgress()
        let sender = Task {
            var index: UInt64 = 0
            while !Task.isCancelled, index < progress.stopIndex {
                index += 1
                var bytes = Data(count: frameBytes)
                bytes.withUnsafeMutableBytes { $0.storeBytes(of: index.littleEndian, as: UInt64.self) }
                do {
                    try await host.send(TransportFrame(lane: lane, bytes: bytes))
                } catch {
                    return
                }
                progress.sent(index: index, bytes: frameBytes, limit: sendLimit)
            }
        }
        defer { sender.cancel() }
        // Wait until the sender is suspended (no progress for a quiet
        // window) or past the limit. Test-only real-time sampling.
        let stalled = try await deadline.run("sender stalls without a consumer") { () -> Int in
            var last = -1
            while true {
                try await Task.sleep(for: .milliseconds(400))
                let now = progress.bytes
                if now >= sendLimit || now == last { return now }
                last = now
            }
        }
        guard stalled <= rawBufferLimitBytes else {
            await dialed.close()
            await host.close()
            throw fail("sender got \(stalled >> 20) MiB accepted with no consumer (limit \(rawBufferLimitBytes >> 20) MiB)")
        }
        guard stalled > 0 else {
            await dialed.close()
            await host.close()
            throw fail("sender made no progress")
        }
        // Read everything: the sender resumes and stops 64 frames later.
        let total = progress.stop(after: 64)
        let events = dialed.events
        let received = try await deadline.run("drain \(total) frames") { () -> UInt64 in
            var expected: UInt64 = 1
            for await event in events {
                switch event {
                case let .frame(frame):
                    guard frame.bytes.count == frameBytes else { throw fail("frame of \(frame.bytes.count) bytes") }
                    let index = frame.bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
                    guard index == expected else { throw fail("frame \(index), expected \(expected)") }
                    if index == total { return index }
                    expected += 1
                case let .closed(reason):
                    throw fail("transport closed while draining: \(reason)")
                default:
                    continue
                }
            }
            throw fail("events ended at frame \(expected)")
        }
        await dialed.close()
        await host.close()
        guard received == total else { throw fail("received \(received) of \(total)") }
        return .passed
    }
}

/// What the raw back-pressure sender got accepted.
final class RawSendProgress: Sendable {
    private struct State {
        var bytes = 0
        var index: UInt64 = 0
        var stopIndex: UInt64 = .max
    }

    // carve-out: test bookkeeping, one arithmetic update per frame.
    private let state = OSAllocatedUnfairLock(initialState: State())

    var bytes: Int { state.withLock { $0.bytes } }

    var stopIndex: UInt64 { state.withLock { $0.stopIndex } }

    func sent(index: UInt64, bytes: Int, limit: Int) {
        state.withLock { state in
            state.index = index
            state.bytes += bytes
            if state.bytes >= limit { state.stopIndex = min(state.stopIndex, index) }
        }
    }

    /// Lets the sender send `extra` more frames, then stop; returns the last index.
    func stop(after extra: UInt64) -> UInt64 {
        state.withLock { state in
            if state.stopIndex == .max { state.stopIndex = state.index + extra }
            return state.stopIndex
        }
    }
}
