public import Foundation
import Synchronization

/// Bounded, demand-driven buffer between an attachment pump and the terminal
/// view that renders its steps (plans/cmux-next/state-audit.md T1).
///
/// Overflow policy: the producer waits while more than `highWater` output
/// bytes are queued, so a view that stops draining stops its pump, the
/// attachment's `TerminalEventQueue` fills, its reader stops reading, and
/// the daemon ends the stream with `overflow` at its 8 MiB mailbox limit.
/// The view then reattaches from a fresh replay. A replay never waits and
/// discards queued output, which it supersedes (the view
/// rebuilds its surface from it). Nothing here grows without bound.
public nonisolated final class TerminalStepQueue: Sendable {
    public let highWater: Int

    private struct State {
        var items: [TerminalStreamPlan.Step] = []
        var head = 0
        var outputBytes = 0
        var finished = false
        var consumer: CheckedContinuation<TerminalStreamPlan.Step?, Never>?
        var producers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init(highWater: Int = 1 << 20) {
        self.highWater = highWater
    }

    /// Output bytes waiting for the consumer (diagnostics, tests).
    public var bufferedOutputBytes: Int { state.withLock { $0.outputBytes } }

    /// Queues `step`, first waiting while the consumer is behind. Returns
    /// at once after ``finish()``.
    public func push(_ step: TerminalStreamPlan.Step) async {
        if case .replay = step {
            enqueue(step, supersede: true)
            return
        }
        while state.withLock({ $0.outputBytes > highWater && !$0.finished }) {
            await withCheckedContinuation { (producer: CheckedContinuation<Void, Never>) in
                let parked = state.withLock { state -> Bool in
                    guard state.outputBytes > highWater, !state.finished else { return false }
                    state.producers.append(producer)
                    return true
                }
                if !parked { producer.resume() }
            }
        }
        enqueue(step, supersede: false)
    }

    /// Ends the stream after what is queued. Releases waiting producers.
    public func finish() {
        let (consumer, producers) = state.withLock { state -> (CheckedContinuation<TerminalStreamPlan.Step?, Never>?, [CheckedContinuation<Void, Never>]) in
            state.finished = true
            let producers = state.producers
            state.producers = []
            guard state.head >= state.items.count else { return (nil, producers) }
            let consumer = state.consumer
            state.consumer = nil
            return (consumer, producers)
        }
        consumer?.resume(returning: nil)
        producers.forEach { $0.resume() }
    }

    /// The consumer went away: drop everything.
    public func cancel() {
        let (consumer, producers) = state.withLock { state -> (CheckedContinuation<TerminalStreamPlan.Step?, Never>?, [CheckedContinuation<Void, Never>]) in
            state.finished = true
            state.items = []
            state.head = 0
            state.outputBytes = 0
            let result = (state.consumer, state.producers)
            state.consumer = nil
            state.producers = []
            return result
        }
        consumer?.resume(returning: nil)
        producers.forEach { $0.resume() }
    }

    /// Next step, or nil once finished and drained. One consumer at a time.
    public func next() async -> TerminalStreamPlan.Step? {
        await withCheckedContinuation { (consumer: CheckedContinuation<TerminalStreamPlan.Step?, Never>) in
            let (ready, producers) = state.withLock { state -> (TerminalStreamPlan.Step??, [CheckedContinuation<Void, Never>]) in
                if state.head < state.items.count {
                    let step = state.items[state.head]
                    state.head += 1
                    state.outputBytes -= Self.outputSize(step)
                    if state.head > 256, state.head * 2 > state.items.count {
                        state.items.removeFirst(state.head)
                        state.head = 0
                    }
                    guard state.outputBytes <= highWater else { return (.some(step), []) }
                    let producers = state.producers
                    state.producers = []
                    return (.some(step), producers)
                }
                if state.finished { return (.some(nil), []) }
                state.consumer = consumer
                return (nil, [])
            }
            producers.forEach { $0.resume() }
            if let ready { consumer.resume(returning: ready) }
        }
    }

    private func enqueue(_ step: TerminalStreamPlan.Step, supersede: Bool) {
        let consumer = state.withLock { state -> CheckedContinuation<TerminalStreamPlan.Step?, Never>? in
            guard !state.finished else { return nil }
            if supersede {
                // Grids stay: they are ordered with the replay and cheap.
                state.items = state.items[state.head...].filter {
                    if case .output = $0 { return false }
                    return true
                }
                state.head = 0
                state.outputBytes = 0
            }
            if let consumer = state.consumer {
                state.consumer = nil
                return consumer
            }
            state.items.append(step)
            state.outputBytes += Self.outputSize(step)
            return nil
        }
        consumer?.resume(returning: step)
    }

    private static func outputSize(_ step: TerminalStreamPlan.Step) -> Int {
        if case .output(let data) = step { return data.count }
        return 0
    }
}
