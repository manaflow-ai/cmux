import CmuxLink
import CmuxLinkTesting
import CmuxLinkWG
import Foundation

/// The two ends of one in-memory underlay (one simulated peer connection).
actor InMemoryUnderlayLink {
    enum Side: Int, Sendable {
        case dialer = 0
        case host = 1

        var other: Side { self == .dialer ? .host : .dialer }
    }

    private var sinks: [AsyncStream<UnderlayEvent>.Continuation?]
    private(set) var path: PathKind
    private var conditions: UnderlayConditions
    private var generator: SeededGenerator
    private let clock: LinkClock
    private var nextFree: [Duration] = [.zero, .zero]
    private(set) var isClosed = false
    private(set) var sentDatagrams = 0

    init(
        path: PathKind,
        conditions: UnderlayConditions,
        seed: UInt64,
        clock: LinkClock,
        sinks: [AsyncStream<UnderlayEvent>.Continuation]
    ) {
        self.path = path
        self.conditions = conditions
        self.clock = clock
        self.sinks = sinks
        generator = SeededGenerator(seed: seed)
    }

    func send(_ datagram: Data, from side: Side) async throws {
        guard !isClosed else { throw InMemoryUnderlayError.closed }
        guard datagram.count <= conditions.maxDatagramBytes else { throw InMemoryUnderlayError.tooLarge }
        if let rate = conditions.bytesPerSecond, rate > 0 {
            let now = clock.now
            let start = max(now, nextFree[side.rawValue])
            let transmit = Duration.seconds(Double(datagram.count) / Double(rate))
            nextFree[side.rawValue] = start + transmit
            let wait = start + transmit - now
            if wait > .zero { try await clock.sleep(for: wait) }
            guard !isClosed else { throw InMemoryUnderlayError.closed }
        }
        sentDatagrams += 1
        if conditions.loss > 0, generator.unit() < conditions.loss { return }
        let copies = conditions.duplication > 0 && generator.unit() < conditions.duplication ? 2 : 1
        for _ in 0..<copies {
            var delay = conditions.latency
            if conditions.jitter > .zero { delay += conditions.jitter * generator.unit() }
            deliver(datagram, to: side.other, after: delay)
        }
    }

    private func deliver(_ datagram: Data, to side: Side, after delay: Duration) {
        guard delay > .zero else {
            sinks[side.rawValue]?.yield(.datagram(datagram))
            return
        }
        let clock = self.clock
        Task {
            try? await clock.sleep(for: delay)
            self.arrive(datagram, at: side)
        }
    }

    private func arrive(_ datagram: Data, at side: Side) {
        guard !isClosed else { return }
        sinks[side.rawValue]?.yield(.datagram(datagram))
    }

    func setConditions(_ conditions: UnderlayConditions) {
        self.conditions = conditions
    }

    func changePath(to kind: PathKind) {
        guard !isClosed else { return }
        path = kind
        for sink in sinks { sink?.yield(.pathChanged(kind)) }
    }

    /// Ends both sides: `side` closed locally, the other sees `.reset`.
    func close(from side: Side) {
        end(dialer: side == .dialer ? .local : .reset, host: side == .host ? .local : .reset)
    }

    func end(dialer: UnderlayCloseReason, host: UnderlayCloseReason) {
        guard !isClosed else { return }
        isClosed = true
        sinks[Side.dialer.rawValue]?.yield(.closed(dialer))
        sinks[Side.host.rawValue]?.yield(.closed(host))
        for sink in sinks { sink?.finish() }
        sinks = [nil, nil]
    }
}
