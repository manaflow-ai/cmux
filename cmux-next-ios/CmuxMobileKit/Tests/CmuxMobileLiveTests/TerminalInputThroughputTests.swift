import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Same harness for base and head: restore only DaemonTerminalSession.swift
/// from the base revision, then run this exact test file again. A synthetic
/// daemon acknowledges sends after 500 ms; both runs type 100 keys at 50/s.
@MainActor @Suite struct TerminalInputThroughputTests {
    @Test func keystrokeThroughputAt500msRTT() async throws {
        for dropFirstReply in [false, true] {
            let channel = LatencyTerminalChannel(dropFirstReply: dropFirstReply)
            let session = DaemonTerminalSession(surface: 7) { DaemonClient(channel: channel) }
            session.tailProbeDelay = .seconds(60)
            session.start { _ in }
            let clock = ContinuousClock()
            let attachDeadline = clock.now.advanced(by: .seconds(3))
            while !session.isAttached, clock.now < attachDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(session.isAttached)
            let began = clock.now
            for _ in 0..<100 {
                session.send(Data("x".utf8))
                try await Task.sleep(for: .milliseconds(20))
            }
            // Record what reached the daemon during the typing interval,
            // rather than counting queued bytes as successful delivery.
            let elapsed = began.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let delivered = channel.sentBytes
            print("TERMINAL_INPUT_PERF rtt_ms=500 first_reply_dropped=\(dropFirstReply) typed=100 delivered=\(delivered) seconds=\(seconds) keys_per_second=\(Double(delivered) / seconds)")
            #expect(delivered > 0)
            session.stop()
            await channel.close(code: "eof", reason: "benchmark complete")
        }
    }
}

private final class LatencyTerminalChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let daemon = FakeTerminalDaemon()
    private let lock = NSLock()
    private let dropFirstReply: Bool
    private var firstSend = true
    private var bytes = 0
    private var closed = false
    private var timers: [UUID: Task<Void, Never>] = [:]
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator

    init(dropFirstReply: Bool) {
        self.dropFirstReply = dropFirstReply
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        iterator = stream.makeAsyncIterator()
    }

    var sentBytes: Int { lock.withLock { bytes } }

    func send(_ data: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: data.split(separator: 0x0A)[0]) as? [String: Any]
        let isInput = object?["cmd"] as? String == "send"
        let replies = daemon.respond("daemon", data)
        guard isInput else {
            for reply in replies { continuation.yield(reply) }
            return
        }
        let shouldDrop = lock.withLock {
            bytes += (object?["bytes"] as? String).flatMap { Data(base64Encoded: $0) }?.count ?? 0
            defer { firstSend = false }
            return firstSend && dropFirstReply
        }
        guard !shouldDrop else { return }
        let id = UUID()
        lock.withLock {
            guard !closed else { return }
            timers[id] = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                let open = self.lock.withLock { self.timers[id] = nil; return !self.closed }
                if open { for reply in replies { self.continuation.yield(reply) } }
            }
        }
    }

    func receive() async throws -> Data? { await iterator.next() }

    func close(code: String, reason: String) async {
        let timers = lock.withLock {
            closed = true
            defer { self.timers.removeAll() }
            return Array(self.timers.values)
        }
        for timer in timers { timer.cancel() }
        continuation.finish()
    }
}
