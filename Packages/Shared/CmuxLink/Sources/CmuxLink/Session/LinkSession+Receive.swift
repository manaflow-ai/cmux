import Foundation

/// Inbound frames and the consumer side of channels: delivery, gaps, acks
/// on consumption.
extension LinkSession {
    // MARK: - Receive

    func receiveData(_ id: UInt32, revision: UInt64, payload: Data) {
        guard var record = channels[id], !record.isClosed else { return }
        let stream = record.descriptor.stream
        switch record.descriptor.reliability {
        case .reliableOrdered:
            if revision <= record.lastReceived {
                if revision <= record.lastConsumed { markAck(id) }
                return
            }
            if revision > record.lastReceived + 1 {
                let gap = ChannelGap(
                    lastDelivered: StreamCursor(stream: stream, epoch: record.cursorEpoch, revision: record.lastReceived),
                    resumedAfter: StreamCursor(stream: stream, epoch: epoch, revision: revision - 1),
                    reason: .retentionExceeded
                )
                record.lastReceived = revision - 1
                channels[id] = record
                deliver(id, .gap(gap))
                guard let refreshed = channels[id] else { return }
                record = refreshed
            }
            record.lastReceived = revision
            channels[id] = record
            deliver(id, .message(LinkMessage(revision: revision, payload: payload)))
        case .partial:
            guard revision > record.lastReceived else { return }
            record.lastReceived = revision
            channels[id] = record
            deliver(id, .message(LinkMessage(revision: revision, payload: payload)))
            trimInbound(id)
        case .unreliableUnordered:
            record.lastReceived = max(record.lastReceived, revision)
            channels[id] = record
            deliver(id, .message(LinkMessage(revision: revision, payload: payload)))
            trimInbound(id)
        }
    }

    func trimInbound(_ id: UInt32) {
        guard var record = channels[id] else { return }
        while record.inboxBytes > record.descriptor.budgetBytes, record.dropOldestInboundMessage() {}
        channels[id] = record
    }

    func receiveGap(_ id: UInt32, resumeAfter: UInt64, reason: GapReason) {
        guard var record = channels[id], !record.isClosed else { return }
        guard record.cursorEpoch != epoch || record.lastReceived != resumeAfter else { return }
        let stream = record.descriptor.stream
        let gap = ChannelGap(
            lastDelivered: StreamCursor(stream: stream, epoch: record.cursorEpoch, revision: record.lastReceived),
            resumedAfter: StreamCursor(stream: stream, epoch: epoch, revision: resumeAfter),
            reason: reason
        )
        record.lastReceived = resumeAfter
        record.cursorEpoch = epoch
        channels[id] = record
        deliver(id, .gap(gap))
    }

    func receiveAck(_ id: UInt32, revision: UInt64) {
        guard var record = channels[id] else { return }
        var released = 0
        var count = 0
        for message in record.retained {
            guard message.revision <= revision else { break }
            released += message.payload.count
            count += 1
        }
        record.retained.removeFirst(count)
        record.retainedBytes -= released
        channels[id] = record
        releaseCredit(id)
    }

    // MARK: - Consumer

    func channelNextEvent(_ id: UInt32, _ incarnation: UInt64) async -> ChannelEvent? {
        guard isLive(id, incarnation), var record = channels[id] else {
            return takeRetired(incarnation)
        }
        if let event = record.popEvent() {
            channels[id] = record
            consumed(id, event)
            return event
        }
        guard !record.finished, record.consumerWaiter == nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ChannelEvent?, Never>) in
                if Task.isCancelled || !isLive(id, incarnation) {
                    continuation.resume(returning: takeRetired(incarnation))
                } else {
                    channels[id]?.consumerWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelConsumer(id, incarnation) }
        }
    }

    /// The next undelivered event of a retired channel.
    func takeRetired(_ incarnation: UInt64) -> ChannelEvent? {
        guard var record = retired[incarnation], let event = record.popEvent() else {
            retired[incarnation] = nil
            return nil
        }
        if case .closed = event {
            retired[incarnation] = nil
        } else {
            retired[incarnation] = record
        }
        return event
    }

    func cancelConsumer(_ id: UInt32, _ incarnation: UInt64) {
        guard isLive(id, incarnation), let waiter = channels[id]?.consumerWaiter else { return }
        channels[id]?.consumerWaiter = nil
        waiter.resume(returning: nil)
    }

    /// Appends an event, or hands it straight to a waiting consumer.
    func deliver(_ id: UInt32, _ event: ChannelEvent) {
        guard var record = channels[id], !record.finished else { return }
        if let waiter = record.consumerWaiter, !record.hasPendingEvents {
            record.consumerWaiter = nil
            channels[id] = record
            consumed(id, event)
            waiter.resume(returning: event)
        } else {
            record.pushEvent(event)
            channels[id] = record
        }
    }

    /// Bookkeeping when the consumer takes an event: the ack that frees the
    /// sender's credit is sent here, not on arrival.
    func consumed(_ id: UInt32, _ event: ChannelEvent) {
        guard var record = channels[id] else { return }
        switch event {
        case let .message(message):
            guard record.descriptor.reliability.isReliable else { return }
            record.lastConsumed = message.revision
            channels[id] = record
            markAck(id)
        case let .gap(gap):
            record.lastConsumed = gap.resumedAfter.revision
            record.cursorEpoch = gap.resumedAfter.epoch
            channels[id] = record
            if record.descriptor.reliability.isReliable { markAck(id) }
        case .closed:
            record.finished = true
            channels[id] = record
            if record.localClosed && record.remoteClosed { retire(id) }
        }
    }

    func markAck(_ id: UInt32) {
        guard current != nil else { return }
        outbound.markAck(id)
        wakePump()
    }
}
