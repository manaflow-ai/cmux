import CmuxFuzzSupport
import Foundation
@testable import CmuxNextDaemon

/// One run of appends, takes and holds against a model of ``EventInbox``'s contract. In normal mode the
/// model is exact: a whole-value event replaces the older one of its key, everything else is kept in order,
/// and one frame is asked for per non-empty buffer. Once the buffer collapsed, it checks what the comment
/// promises: the overflow marker first, lifecycle and out-of-snapshot events kept, the newest agent status,
/// presence and registry stamp kept once, each transaction echoed once, the rest dropped, wire order kept.
struct WireFuzzInboxSequence {
    enum Op {
        case append(DaemonEventEnvelope)
        case take
        case hold
    }

    let limit: Int
    let ops: [Op]

    init(_ rng: inout FuzzRNG) {
        limit = rng.oneIn(8) ? EventInbox.defaultLimit : 1 + rng.below(12)
        let sources: [UUID?] = [nil, UUID(uuidString: "00000000-0000-0000-0000-00000000000A"),
                                UUID(uuidString: "00000000-0000-0000-0000-00000000000B")]
        var sequence: UInt64 = 0
        var ops: [Op] = []
        for _ in 0..<rng.below(80) {
            switch rng.below(12) {
            case 0:
                ops.append(.take)
            case 1 where rng.oneIn(3):
                ops.append(.hold)
            default:
                sequence += 1
                let (event, isRegistry) = Self.event(&rng)
                let source = isRegistry ? sources[rng.below(sources.count)] : nil
                ops.append(.append(DaemonEventEnvelope(sequence: sequence, event: event, sourceID: source)))
            }
        }
        self.ops = ops
    }

    static func event(_ rng: inout FuzzRNG) -> (DaemonEvent, isRegistry: Bool) {
        let surface = SurfaceID(rawValue: UInt64(1 + rng.below(4)))
        let transaction: ClientTransactionID? = rng.oneIn(3) ? nil : ClientTransactionID(rawValue: "t\(rng.below(5))")
        let event: DaemonEvent
        switch rng.below(14) {
        case 0: event = .titleChanged(surface: surface, title: "v\(rng.below(100))")
        case 1:
            let cols = rng.below(300)
            event = .surfaceResized(surface: surface, size: CellSize(cols: cols, rows: rng.below(100)))
        case 2: event = .scrollChanged(surface: surface, offset: UInt64(rng.below(1000)), atBottom: rng.bool())
        case 3: event = .agentPresenceChanged(AgentPresence(surface: surface, activity: rng.oneIn(3) ? nil : .editing))
        case 4:
            let states: [AgentState] = [.working, .idle, .blocked, .done]
            let state = states[rng.below(states.count)]
            event = .agentChanged(AgentStatus(surface: surface, state: state, updatedAtMs: UInt64(rng.below(1000))))
        case 5: event = .bell(surface: surface)
        case 6: event = .treeChanged(transaction: transaction)
        case 7: event = .layoutChanged(screen: ScreenID(rawValue: UInt64(1 + rng.below(3))), layout: nil, transaction: transaction)
        case 8: return (.terminalRegistryChanged(revision: UInt64(rng.below(100))), true)
        case 9: event = .disconnected(reason: "r\(rng.below(10))")
        case 10: event = .daemonShutdown
        case 11: event = .keybindingsChanged(revision: UInt64(rng.below(100)))
        case 12: event = .personalChanged
        default: event = .unknown(name: "apps-fuzz", payload: .number(Double(rng.below(10))))
        }
        return (event, false)
    }

    /// What the model holds since the last take.
    private struct Window {
        var appended: [DaemonEventEnvelope] = []
        var model: [DaemonEventEnvelope] = []
        var collapsed = false
    }

    func check() throws {
        let inbox = EventInbox(limit: limit)
        var window = Window()
        var framePending = false
        var coalesced = 0
        for (step, op) in ops.enumerated() {
            switch op {
            case .append(let envelope):
                let asked = inbox.append(envelope)
                try FuzzRun.check(asked == !framePending, "step \(step): append asked for a frame: \(asked), one was pending: \(framePending)")
                framePending = true
                window.appended.append(envelope)
                guard !window.collapsed else { break }
                let key = CoalesceKey(envelope.event)
                if let key, let old = window.model.firstIndex(where: { CoalesceKey($0.event) == key }) {
                    window.model.remove(at: old)
                    window.model.append(envelope)
                    coalesced += 1
                } else if window.model.count >= limit {
                    window.collapsed = true
                } else {
                    window.model.append(envelope)
                }
            case .hold:
                inbox.hold()
                framePending = true
            case .take:
                try take(inbox, window, step: step)
                window = Window()
                framePending = false
            }
            try FuzzRun.check(inbox.coalescedCount == coalesced, "step \(step): \(inbox.coalescedCount) coalesced, the model \(coalesced)")
        }
        try take(inbox, window, step: ops.count)
        try FuzzRun.check(inbox.append(DaemonEventEnvelope(sequence: UInt64.max, event: .bell(surface: 1))),
                          "the append after a take did not ask for a frame")
    }

    private func take(_ inbox: EventInbox, _ window: Window, step: Int) throws {
        let buffered = inbox.bufferedCount
        let batch = inbox.take()
        try FuzzRun.check(buffered == batch.count, "step \(step): \(buffered) buffered but \(batch.count) taken")
        try FuzzRun.check(inbox.bufferedCount == 0 && inbox.take().isEmpty, "step \(step): a take left events behind")
        if window.collapsed {
            try Self.checkCollapsed(batch, appended: window.appended, step: step)
        } else {
            try FuzzRun.check(batch == window.model, "step \(step): batch \(Self.describe(batch)), the model \(Self.describe(window.model))")
            try FuzzRun.check(batch.count <= limit, "step \(step): \(batch.count) events past the limit \(limit) without a collapse")
        }
    }

    /// The groups a collapsed inbox keeps only the newest event of.
    private static var newestOnly: [(label: String, key: (DaemonEventEnvelope) -> AnyHashable?)] { [
        ("agent status", { envelope in
            guard case .agentChanged(let status) = envelope.event else { return nil }
            return AnyHashable(status.surface)
        }),
        ("agent presence", { envelope in
            guard case .agentPresenceChanged(let presence) = envelope.event else { return nil }
            return AnyHashable(presence.surface)
        }),
        ("registry stamp", { envelope in
            guard case .terminalRegistryChanged = envelope.event else { return nil }
            return AnyHashable(envelope.sourceID?.uuidString ?? "none")
        }),
    ] }

    private static func checkCollapsed(_ batch: [DaemonEventEnvelope], appended: [DaemonEventEnvelope], step: Int) throws {
        let at = "step \(step) (collapsed)"
        guard case .overflow(let reason)? = batch.first?.event, reason.hasPrefix("app event inbox exceeded") else {
            throw FuzzError.property("\(at): the batch does not start with the inbox's overflow marker: \(describe(batch))",
                                     location: "WireFuzzInboxSequence")
        }
        let rest = Array(batch.dropFirst())
        try FuzzRun.check(zip(rest, rest.dropFirst()).allSatisfy { $0.sequence < $1.sequence }, "\(at): out of wire order: \(describe(rest))")
        let sources = Dictionary(appended.map { ($0.sequence, $0) }, uniquingKeysWith: { first, _ in first })
        for envelope in rest {
            let source = try WireFuzzJSON.required(sources[envelope.sequence], "\(at): \(envelope) was never appended")
            guard envelope != source else { continue }
            guard case .treeChanged(let transaction?) = envelope.event, transaction == source.event.clientTransactionID else {
                throw FuzzError.property("\(at): \(envelope) is neither \(source) nor its echo", location: "WireFuzzInboxSequence")
            }
        }
        let held = Set(rest)
        for envelope in appended where alwaysKept(envelope.event) {
            try FuzzRun.check(held.contains(envelope), "\(at): \(envelope) was dropped")
        }
        for envelope in rest {
            try FuzzRun.check(!droppedWhenCollapsed(envelope.event), "\(at): \(envelope) outlived the collapse")
        }
        for (label, key) in newestOnly {
            let newest = Dictionary(appended.compactMap { envelope in key(envelope).map { ($0, envelope) } },
                                    uniquingKeysWith: { _, last in last })
            for (group, envelope) in newest {
                let kept = rest.filter { key($0) == group }
                try FuzzRun.check(kept == [envelope], "\(at): \(label) \(group): kept \(describe(kept)), want only the newest \(envelope)")
            }
        }
        for transaction in Set(appended.compactMap(\.event.clientTransactionID)) {
            let echoes = rest.filter { $0.event.clientTransactionID == transaction }.count
            try FuzzRun.check(echoes == 1, "\(at): transaction \(transaction) shows \(echoes) times, want once")
        }
    }

    /// Kept through a collapse and never coalesced: lifecycle, and events no tree snapshot carries.
    private static func alwaysKept(_ event: DaemonEvent) -> Bool {
        switch event {
        case .disconnected, .daemonShutdown, .keybindingsChanged, .unknown: true
        default: false
        }
    }

    /// A refetched snapshot carries them: dropped once the inbox collapsed (a transaction survives as an echo).
    private static func droppedWhenCollapsed(_ event: DaemonEvent) -> Bool {
        switch event {
        case .titleChanged, .surfaceResized, .scrollChanged, .bell, .personalChanged, .layoutChanged, .overflow: true
        case .treeChanged(let transaction): transaction == nil
        default: false
        }
    }

    private static func describe(_ batch: [DaemonEventEnvelope]) -> String {
        "[" + batch.map { "\($0.sequence):\(String(describing: $0.event).prefix(40))" }.joined(separator: ", ") + "]"
    }
}

/// Producer threads that append and now and then take, all at once on one inbox.
struct WireFuzzInboxThreads {
    let plans: [[Bool]]

    init(_ rng: inout FuzzRNG) {
        let threads = 2 + rng.below(5)
        let takeOdds = 4 + rng.below(40)
        var plans: [[Bool]] = []
        for _ in 0..<threads {
            let steps = 20 + rng.below(400)
            plans.append((0..<steps).map { _ in rng.oneIn(takeOdds) })
        }
        self.plans = plans
    }

    static func sequence(thread: Int, step: Int) -> UInt64 {
        UInt64(thread) << 32 | UInt64(step)
    }

    func check() throws {
        let inbox = EventInbox(limit: 1 << 30)
        let log = WireFuzzLocked<[DaemonEventEnvelope]>([])
        let frames = WireFuzzLocked(0)
        let takes = WireFuzzLocked(0)
        let plans = self.plans
        DispatchQueue.concurrentPerform(iterations: plans.count) { thread in
            for (step, takesNow) in plans[thread].enumerated() {
                if takesNow {
                    // Under the log's lock, so the log holds the batches in the order they were taken.
                    log.withLock { $0.append(contentsOf: inbox.take()) }
                    takes.withLock { $0 += 1 }
                } else {
                    let envelope = DaemonEventEnvelope(sequence: Self.sequence(thread: thread, step: step),
                                                       event: .bell(surface: SurfaceID(rawValue: UInt64(thread))))
                    if inbox.append(envelope) { frames.withLock { $0 += 1 } }
                }
            }
        }
        log.withLock { $0.append(contentsOf: inbox.take()) }
        let delivered = log.withLock { $0 }
        let appended = plans.map { $0.filter { !$0 }.count }.reduce(0, +)
        try FuzzRun.check(delivered.count == appended, "\(delivered.count) events delivered of \(appended) appended")
        for thread in plans.indices {
            let expected = plans[thread].indices.filter { !plans[thread][$0] }.map { Self.sequence(thread: thread, step: $0) }
            let got = delivered.filter { $0.sequence >> 32 == UInt64(thread) }.map(\.sequence)
            try FuzzRun.check(got == expected, "thread \(thread): its events arrived out of order or not once each")
        }
        // The first append asks; after that at most one more per take that came before an append.
        let asked = frames.withLock { $0 }
        let taken = takes.withLock { $0 } + 1
        try FuzzRun.check(appended == 0 || (1...taken).contains(asked), "\(asked) frames asked for over \(taken) takes")
    }
}
