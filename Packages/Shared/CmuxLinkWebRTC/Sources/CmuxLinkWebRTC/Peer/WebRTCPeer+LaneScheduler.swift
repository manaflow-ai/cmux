import CmuxLink
import Foundation
@preconcurrency import WebRTC

/// The lane scheduler (d2-bakeoff.md F1): one task per peer connection
/// moves queued lane messages into libwebrtc, always from the highest
/// priority lane that has a message and whose channel is open with
/// `bufferedAmount` at or below `channelHighWater`. A keystroke therefore
/// waits behind at most one 8 KiB piece of bulk per channel buffer, and the
/// SCTP send buffer never takes a burst larger than the high-water mark. It
/// sleeps on `wakes` (a send queued, a channel opened, a buffer drained),
/// never on a timer.
extension WebRTCPeer {
    private struct Candidate {
        let key: String
        let channel: RTCDataChannel
        let priority: ChannelPriority
        let reliable: Bool
    }

    func startScheduler() {
        let wakes = wakes
        Task { [weak self] in
            for await _ in wakes {
                guard let self else { return }
                // One drain can move hundreds of MiB without suspending; each
                // send drains the autorelease pool its libwebrtc calls fill.
                while autoreleasepool(invoking: { self.sendOne() }) {}
            }
        }
    }

    /// Sends one message; false when nothing is sendable right now.
    private func sendOne() -> Bool {
        let candidates = state.withLockUnchecked { state -> [Candidate] in
            guard !state.closed else { return [] }
            return state.laneQueues
                .filter { !$0.value.isEmpty }
                .sorted { $0.value.label.lane.priority < $1.value.label.lane.priority }
                .compactMap { key, queue in
                    state.sendChannels[key].map {
                        Candidate(key: key, channel: $0, priority: queue.label.lane.priority,
                                  reliable: queue.label.lane.reliability.isReliable)
                    }
                }
        }
        let windowOpen = state.withLockUnchecked { $0.sentBytes - $0.creditedBytes < limits.inFlightWindow }
        // libwebrtc is asked outside the lock (lock rule, WebRTCPeer).
        guard let pick = candidates.first(where: {
            // Input and control lanes (keystrokes, acks) bypass the window.
            ($0.priority <= .control || !$0.reliable || windowOpen)
                && $0.channel.readyState == .open && $0.channel.bufferedAmount <= limits.channelHighWater
        }) else { return false }
        let popped = state.withLockUnchecked { state -> (LaneQueue.Message, Bool)? in
            guard !state.closed, let message = state.laneQueues[pick.key]?.popFirst() else { return nil }
            return (message, state.laneQueues[pick.key]?.label.lane.reliability.isReliable ?? false)
        }
        guard let (message, reliable) = popped else { return true }
        let sent = pick.channel.sendData(RTCDataBuffer(data: message.bytes, isBinary: true))
        let (room, flushed) = state.withLockUnchecked { state -> ([CheckedContinuation<Void, any Error>], [CheckedContinuation<Void, Never>]) in
            if sent, reliable {
                state.sentBytes += message.bytes.count
                if message.endsFrame { state.sentCounts[pick.key, default: 0] += 1 }
            }
            var room: [CheckedContinuation<Void, any Error>] = []
            if (state.laneQueues[pick.key]?.queuedBytes ?? 0) < limits.laneBudget {
                room = state.roomWaiters.removeValue(forKey: pick.key)?.sorted { $0.key < $1.key }.map(\.value) ?? []
            }
            var flushed: [CheckedContinuation<Void, Never>] = []
            if Self.reliableQueuesEmpty(state) {
                flushed = state.flushWaiters
                state.flushWaiters = []
            }
            return (room, flushed)
        }
        for waiter in room { waiter.resume() }
        for waiter in flushed { waiter.resume() }
        return true
    }

    /// The peer received `received` reliable bytes in total.
    func credited(_ received: Int) {
        let opened = state.withLockUnchecked { state -> Bool in
            guard received > state.creditedBytes else { return false }
            state.creditedBytes = received
            return true
        }
        if opened { wakeSink.yield() }
    }

    /// Receiver side: the consumer took a reliable frame of `bytes` message bytes.
    func consumed(_ bytes: Int) {
        state.withLockUnchecked { $0.consumedBytes += bytes }
        creditIfDue()
    }

    /// Receiver side: credits the peer once the credit (bytes of frames the
    /// consumer took plus pieces still reassembling) moved `creditEvery` past
    /// the last credit sent. Never lowers it: a completed frame leaves the
    /// reassembling count before the consumer takes it.
    func creditIfDue() {
        let due = state.withLockUnchecked { state -> Int? in
            let credit = state.consumedBytes + state.partialTotal
            guard credit - state.creditSent >= limits.creditEvery else { return nil }
            state.creditSent = credit
            return credit
        }
        if let due { _ = sendControl(.credit(received: due)) }
    }

    private static func reliableQueuesEmpty(_ state: State) -> Bool {
        state.laneQueues.values.allSatisfy { $0.isEmpty || !$0.label.lane.reliability.isReliable }
    }

    /// Suspends while `key`'s queue is at or over the lane budget.
    func waitForRoom(_ key: String) async throws {
        let waiterID = state.withLockUnchecked { state -> UInt64 in
            defer { state.nextRoomWaiterID &+= 1 }
            return state.nextRoomWaiterID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome = state.withLockUnchecked { state -> Result<Bool, any Error> in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.closed { return .failure(WebRTCPeerError.closed) }
                    if (state.laneQueues[key]?.queuedBytes ?? 0) < limits.laneBudget { return .success(true) }
                    state.roomWaiters[key, default: [:]][waiterID] = continuation
                    return .success(false)
                }
                switch outcome {
                case .success(true): continuation.resume()
                case .success(false): break
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.cancelRoomWaiter(key: key, id: waiterID)
        }
    }

    private func cancelRoomWaiter(key: String, id: UInt64) {
        let waiter = state.withLockUnchecked { state -> CheckedContinuation<Void, any Error>? in
            guard var waiters = state.roomWaiters[key], let continuation = waiters.removeValue(forKey: id) else {
                return nil
            }
            if waiters.isEmpty {
                state.roomWaiters.removeValue(forKey: key)
            } else {
                state.roomWaiters[key] = waiters
            }
            return continuation
        }
        waiter?.resume(throwing: CancellationError())
    }

    /// Returns once every reliable lane message queued so far was handed to
    /// libwebrtc (or the peer closed), so a `fin` follows them.
    func waitFlushed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done = state.withLockUnchecked { state -> Bool in
                if state.closed || Self.reliableQueuesEmpty(state) { return true }
                state.flushWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
}
