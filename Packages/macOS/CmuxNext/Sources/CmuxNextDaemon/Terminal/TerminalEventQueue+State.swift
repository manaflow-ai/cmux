import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import Foundation

extension TerminalEventQueue {
    /// What the queue holds and where it is in a resync; read and changed only under the queue's lock.
    struct State {
        var items: [TerminalChannelEvent] = []
        var head = 0
        /// Bulk bytes queued: output and snapshot history (the parking bound).
        var outputBytes = 0
        /// Live output bytes queued (the resync bound).
        var liveOutputBytes = 0
        /// Fresh states (READY, replay, resized) queued that the consumer has not taken.
        var queuedFreshStates = 0
        var waiter: OnceContinuation<TerminalChannelEvent?, OnceContinuationError>?
        var finished = false
        var armed = false
        /// The reader waits on `readerWake`; whoever clears this signals it exactly once.
        var readerParked = false
        var resync = ResyncPhase.idle
        /// Counts the requests that entered ``ResyncPhase/awaitingReady``: an answer to, or a retry of,
        /// an older one changes nothing.
        var resyncEpoch: UInt64 = 0
        /// A READY was queued: a snapshot attach, which resyncs in place.
        var snapshotAttach = false
        var overflows = 0
        var resyncRequests = 0
        var droppedEvents = 0

        mutating func append(_ event: TerminalChannelEvent) {
            items.append(event)
            outputBytes += TerminalEventQueue.outputSize(event)
            liveOutputBytes += TerminalEventQueue.liveOutputSize(event)
            if TerminalEventQueue.startsFreshState(event) { queuedFreshStates += 1 }
        }

        /// Replaces the queued events with `kept`, counting the rest as dropped.
        mutating func replacePending(with kept: [TerminalChannelEvent]) {
            droppedEvents += items.count - head - kept.count
            items = []
            head = 0
            outputBytes = 0
            liveOutputBytes = 0
            queuedFreshStates = 0
            for event in kept { append(event) }
        }

        /// Whether the reader must wait now (armed, not finished, above `highWater`); marks it parked if so.
        mutating func parkReader(above highWater: Int) -> Bool {
            readerParked = armed && !finished && outputBytes > highWater
            return readerParked
        }

        /// Clears the parked mark; true when the caller must signal the reader.
        mutating func releaseReader() -> Bool {
            defer { readerParked = false }
            return readerParked
        }

        /// Whether `event` is dropped because a fresh state will replace it. Any fresh state (the
        /// requested READY, or one the daemon sent on its own) covers the dropped output, ends the
        /// resync and is queued. While deferred, the queued READY's history still goes through.
        mutating func dropWhileResyncing(_ event: TerminalChannelEvent) -> Bool {
            guard resync != .idle else { return false }
            if TerminalEventQueue.startsFreshState(event) {
                resync = .idle
                return false
            }
            let drops = resync == .deferred
                ? TerminalEventQueue.isLiveContent(event)
                : TerminalEventQueue.isSupersededByReady(event)
            if drops { droppedEvents += 1 }
            return drops
        }

        /// Whether queuing `live` more output bytes overflows. An item is admitted when no output is
        /// queued even if it alone is larger, so one oversized chunk cannot resync forever.
        func overflows(adding live: Int, highWater: Int) -> Bool {
            armed && live > 0 && liveOutputBytes > 0 && liveOutputBytes + live > highWater
        }

        /// Drops every queued event a fresh READY supersedes; size, color and scroll states stay in order.
        mutating func dropSuperseded() {
            replacePending(with: items.dropFirst(head).filter { !TerminalEventQueue.isSupersededByReady($0) })
        }

        /// Keeps the newest queued fresh state, its history and every size, color and scroll state. Drops
        /// what that state supersedes before it, and the output after it, which no longer continues it
        /// once a chunk is lost.
        mutating func keepNewestFreshState() {
            let pending = Array(items.dropFirst(head))
            guard let newest = pending.lastIndex(where: TerminalEventQueue.startsFreshState) else { return }
            let kept = pending.enumerated().compactMap { offset, event -> TerminalChannelEvent? in
                let keep = offset < newest
                    ? !TerminalEventQueue.isSupersededByReady(event)
                    : offset == newest || !TerminalEventQueue.isLiveContent(event)
                return keep ? event : nil
            }
            replacePending(with: kept)
        }

        /// Sends a new request: answers to an older one change nothing from now on.
        mutating func beginResync() -> UInt64 {
            resync = .awaitingReady
            resyncEpoch += 1
            resyncRequests += 1
            return resyncEpoch
        }

        /// Whether the request of `epoch` still waits for its READY.
        func awaitsReady(epoch: UInt64) -> Bool {
            !finished && resync == .awaitingReady && resyncEpoch == epoch
        }

        /// The consumer took the last queued fresh state of a deferred resync: the epoch of the request
        /// to send now, else nil.
        mutating func takeDeferredResync() -> UInt64? {
            guard resync == .deferred, queuedFreshStates == 0, !finished else { return nil }
            return beginResync()
        }

        /// Next event, merging consecutive plain output chunks up to `mergeLimit`; nil when none is queued.
        mutating func popMerged(mergeLimit: Int, recorder: DaemonWireStats.Recorder?) -> TerminalChannelEvent? {
            guard var event = items[checked: head] else { return nil }
            head += 1
            if case .output(var data, nil) = event {
                var merged = false
                while data.count < mergeLimit, case .output(let more, nil)? = items[checked: head] {
                    data.append(more)
                    head += 1
                    merged = true
                }
                // A merge writes every byte of the result into a new buffer.
                if merged { recorder?.outputCopied(data.count) }
                event = .output(data, colors: nil)
                outputBytes -= data.count
                liveOutputBytes -= data.count
            } else {
                outputBytes -= TerminalEventQueue.outputSize(event)
                liveOutputBytes -= TerminalEventQueue.liveOutputSize(event)
                if TerminalEventQueue.startsFreshState(event) { queuedFreshStates -= 1 }
            }
            if head > 256, head * 2 > items.count {
                items.removeFirst(head)
                head = 0
            }
            return event
        }
    }

    /// Bulk bytes: output and snapshot history. A READY, like a replay,
    /// never blocks the reader (it is one screen, sent before the attach
    /// reply on attach).
    static func outputSize(_ event: TerminalChannelEvent) -> Int {
        switch event {
        case .output(let data, _): data.count
        case .snapshot(let frame) where frame.phase != .ready: frame.data.count
        default: 0
        }
    }

    /// Live output bytes: what a ``Backpressure/dropAndResync(_:)`` queue bounds. A READY's history
    /// answers a resync, a resize or the attach, so it never triggers one.
    static func liveOutputSize(_ event: TerminalChannelEvent) -> Int {
        if case .output(let data, _) = event { data.count } else { 0 }
    }

    /// Live output and its echo marks: they continue the last fresh state, and are wrong once a chunk is lost.
    static func isLiveContent(_ event: TerminalChannelEvent) -> Bool {
        switch event {
        case .output, .inputEcho: true
        default: false
        }
    }

    /// A full terminal state the view applies in place of what it had: a READY or a replay.
    static func startsFreshState(_ event: TerminalChannelEvent) -> Bool {
        switch event {
        case .snapshot(let frame): frame.phase == .ready
        case .replay, .resized: true
        default: false
        }
    }

    /// Terminal content a later READY replaces: output, its echo marks and older snapshots. Size, color and
    /// scroll states and the end of the stream are kept, in order.
    static func isSupersededByReady(_ event: TerminalChannelEvent) -> Bool {
        switch event {
        case .output, .inputEcho, .snapshot, .replay, .resized: true
        case .colorsChanged, .scrollChanged, .sizeState, .closed: false
        }
    }
}
