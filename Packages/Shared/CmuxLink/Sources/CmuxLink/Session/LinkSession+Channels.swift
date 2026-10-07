import Foundation

/// Channel operations for features and inbound frame handling.
extension LinkSession {
    // MARK: - Open

    public func openChannel(_ descriptor: ChannelDescriptor, resumeFrom cursor: StreamCursor?) throws -> LinkChannel {
        if case let .closed(reason) = machine.state { throw LinkError.closed(reason) }
        let id = nextChannelID
        nextChannelID &+= 2
        let record = ChannelRecord(
            id: id, descriptor: descriptor, openedLocally: true,
            cursorEpoch: cursor?.epoch ?? epoch, lastReceived: cursor?.revision ?? 0
        )
        channels[id] = record
        if current != nil, pendingDial == nil, machine.state.isLive {
            enqueueOpen(id)
        }
        return LinkChannel(id: id, descriptor: descriptor, session: self)
    }

    /// Re-declares channels on a fresh transport: locally opened channels
    /// send `open` with their cursor; closes the peer never echoed are sent
    /// again; channels the peer opened wait for the peer's `open`.
    func redeclareChannels() {
        for id in channels.keys.sorted() {
            guard var record = channels[id] else { continue }
            record.phase = .awaiting
            record.closeQueued = false
            channels[id] = record
            if record.localClosed && record.remoteClosed {
                removeIfDone(id, force: true)
            } else if record.openedLocally && !record.remoteClosed {
                // Locally closed channels re-declare too, so retained data
                // replays before their close.
                enqueueOpen(id)
            }
        }
        wakePump()
    }

    /// The channel is declared on the current transport: replay what the
    /// peer misses, then a close this side asked for.
    func channelBecameOpen(_ id: UInt32, peerEpoch: UInt64, peerRevision: UInt64) {
        resumeOutbound(id, peerEpoch: peerEpoch, peerRevision: peerRevision)
        guard let record = channels[id], record.localClosed, !record.closeQueued else { return }
        channels[id]?.closeQueued = true
        enqueueChannelControl(id, frame: .close(channel: id))
    }

    func enqueueOpen(_ id: UInt32) {
        guard let record = channels[id] else { return }
        enqueueChannelControl(id, frame: .open(
            channel: id, descriptor: record.descriptor,
            cursorEpoch: record.cursorEpoch, cursorRevision: record.lastReceived
        ))
    }

    /// Channel-scoped control frames ride the channel's reliable lane at its
    /// priority, so carriers that map lanes to separate streams keep them in
    /// order with the channel's reliable data.
    func enqueueChannelControl(_ id: UInt32, frame: LinkFrame) {
        guard let record = channels[id] else { return }
        let lane = TransportLane(reliability: .reliableOrdered, priority: record.descriptor.priority)
        let item = OutboundItem(frame: frame, lane: lane, bytes: 32, enqueuedAt: clock.now)
        switch frame {
        case .close:
            outbound.enqueue(item, priority: record.descriptor.priority)
        default:
            outbound.enqueueControl(item)
        }
        wakePump()
    }

    func peerOpened(_ id: UInt32, descriptor: ChannelDescriptor, cursorEpoch: UInt64, cursorRevision: UInt64) {
        guard current != nil else { return }
        if channels[id] == nil {
            let peerParity: UInt32 = isDialer ? 0 : 1
            guard id % 2 == peerParity else {
                finish(.protocolViolation("channel id parity"), notifyPeer: true)
                return
            }
            channels[id] = ChannelRecord(
                id: id, descriptor: descriptor, openedLocally: false, cursorEpoch: epoch, lastReceived: 0
            )
            deliverIncoming(LinkChannel(id: id, descriptor: descriptor, session: self))
        }
        guard var record = channels[id], !record.remoteClosed else { return }
        record.phase = .open
        record.everOpened = true
        channels[id] = record
        enqueueChannelControl(id, frame: .openAck(channel: id, epoch: epoch, revision: record.lastReceived))
        channelBecameOpen(id, peerEpoch: cursorEpoch, peerRevision: cursorRevision)
    }

    func peerAcknowledgedOpen(_ id: UInt32, revision: UInt64) {
        guard var record = channels[id], record.openedLocally, !record.remoteClosed else { return }
        record.phase = .open
        record.everOpened = true
        channels[id] = record
        channelBecameOpen(id, peerEpoch: epoch, peerRevision: revision)
    }

    // MARK: - Send

    func channelSend(_ id: UInt32, _ payload: Data) async throws -> UInt64 {
        let size = payload.count
        let limit = min(configuration.maxFrameBytes, current?.capabilities.maxFrameBytes ?? .max)
        guard size + LinkFrame.dataOverhead <= limit else {
            throw LinkError.messageTooLarge(size: size, limit: limit - LinkFrame.dataOverhead)
        }
        try checkSendable(id)
        guard let descriptor = channels[id]?.descriptor else { throw LinkError.channelClosed }
        if descriptor.reliability.isReliable {
            while let record = channels[id], record.retainedBytes > 0,
                  record.retainedBytes + size > descriptor.budgetBytes {
                try await waitForCredit(id)
                try checkSendable(id)
            }
            guard var record = channels[id] else { throw LinkError.channelClosed }
            let revision = record.nextRevision
            record.nextRevision += 1
            record.retained.append(LinkMessage(revision: revision, payload: payload))
            record.retainedBytes += size
            channels[id] = record
            if record.phase == .open, current != nil, canCarry(descriptor) {
                enqueueData(id, revision: revision, payload: payload)
            }
            return revision
        }
        guard var record = channels[id] else { throw LinkError.channelClosed }
        let revision = record.nextRevision
        record.nextRevision += 1
        channels[id] = record
        if record.phase == .open, current != nil, canCarry(descriptor) {
            enqueueData(id, revision: revision, payload: payload)
        }
        return revision
    }

    func checkSendable(_ id: UInt32) throws {
        if case let .closed(reason) = machine.state { throw LinkError.closed(reason) }
        guard let record = channels[id], !record.isClosed else { throw LinkError.channelClosed }
        if let current, record.descriptor.priority == .bulk, !current.capabilities.carriesBulk {
            throw LinkError.unsupportedOnPath(current.path.kind)
        }
    }

    func canCarry(_ descriptor: ChannelDescriptor) -> Bool {
        guard let current else { return false }
        return descriptor.priority != .bulk || current.capabilities.carriesBulk
    }

    func enqueueData(_ id: UInt32, revision: UInt64, payload: Data) {
        guard var record = channels[id] else { return }
        let descriptor = record.descriptor
        let lane = TransportLane(reliability: descriptor.reliability, priority: descriptor.priority)
        var item = OutboundItem(
            frame: .data(channel: id, revision: revision, payload: payload),
            lane: lane, bytes: payload.count, enqueuedAt: clock.now
        )
        if !descriptor.reliability.isReliable {
            item.budgetChannel = id
            if case let .partial(lifetime) = descriptor.reliability { item.lifetime = lifetime }
            while record.queuedBytes > 0, record.queuedBytes + payload.count > descriptor.budgetBytes,
                  let dropped = outbound.dropOldest(channel: id, priority: descriptor.priority) {
                record.queuedBytes -= dropped
            }
            record.queuedBytes += payload.count
            channels[id] = record
        }
        outbound.enqueue(item, priority: descriptor.priority)
        wakePump()
    }

    func waitForCredit(_ id: UInt32) async throws {
        let waiter = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if channels[id] == nil {
                    continuation.resume(throwing: LinkError.channelClosed)
                } else {
                    channels[id]?.creditWaiters[waiter] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCreditWaiter(id, waiter) }
        }
    }

    func cancelCreditWaiter(_ id: UInt32, _ waiter: UInt64) {
        channels[id]?.creditWaiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }

    func channelFlush(_ id: UInt32) async throws {
        if case let .closed(reason) = machine.state { throw LinkError.closed(reason) }
        guard let record = channels[id], !record.retained.isEmpty else { return }
        let waiter = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    channels[id]?.flushWaiters[waiter] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelFlushWaiter(id, waiter) }
        }
    }

    func cancelFlushWaiter(_ id: UInt32, _ waiter: UInt64) {
        channels[id]?.flushWaiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }

    func channelCursor(_ id: UInt32, stream: String) -> StreamCursor {
        let record = channels[id]
        return StreamCursor(stream: stream, epoch: record?.cursorEpoch ?? epoch, revision: record?.lastConsumed ?? 0)
    }

    // MARK: - Close

    func channelClose(_ id: UInt32) {
        guard var record = channels[id], !record.localClosed else { return }
        record.localClosed = true
        channels[id] = record
        if record.remoteClosed {
            removeIfDone(id)
            return
        }
        failWaiters(id, error: LinkError.channelClosed)
        channels[id]?.clearInbox()
        deliver(id, .closed(.local))
        if record.phase == .open, current != nil {
            // FIFO behind this channel's queued data at its priority.
            channels[id]?.closeQueued = true
            enqueueChannelControl(id, frame: .close(channel: id))
        } else if !record.openedLocally && !record.everOpened {
            removeIfDone(id, force: true)
        }
        // Otherwise the close follows the next open handshake.
    }

    func receiveClose(_ id: UInt32) {
        guard var record = channels[id] else { return }
        if record.localClosed {
            record.remoteClosed = true
            channels[id] = record
            removeIfDone(id, force: true)
            return
        }
        record.remoteClosed = true
        channels[id] = record
        failWaiters(id, error: LinkError.channelClosed)
        deliver(id, .closed(.remote))
        enqueueChannelControl(id, frame: .close(channel: id))
    }

    /// Ends a channel when the session closes.
    func endChannel(_ id: UInt32, reason: ChannelCloseReason, error: any Error) {
        guard var record = channels[id] else { return }
        let wasClosed = record.isClosed
        record.localClosed = true
        record.remoteClosed = true
        channels[id] = record
        failWaiters(id, error: error)
        if !wasClosed { deliver(id, .closed(reason)) }
        if let waiter = channels[id]?.consumerWaiter, channels[id]?.hasPendingEvents == false {
            channels[id]?.consumerWaiter = nil
            waiter.resume(returning: nil)
        }
    }

    func failWaiters(_ id: UInt32, error: any Error) {
        guard var record = channels[id] else { return }
        let credit = record.creditWaiters.values
        let flush = record.flushWaiters.values
        record.creditWaiters.removeAll()
        record.flushWaiters.removeAll()
        channels[id] = record
        for waiter in credit { waiter.resume(throwing: error) }
        for waiter in flush { waiter.resume(throwing: error) }
    }

    /// Drops a record once both sides closed and the consumer took `.closed`.
    func removeIfDone(_ id: UInt32, force: Bool = false) {
        guard let record = channels[id] else { return }
        guard force || (record.localClosed && record.remoteClosed) else { return }
        guard record.finished || !record.hasPendingEvents else { return }
        if let waiter = record.consumerWaiter {
            channels[id]?.consumerWaiter = nil
            waiter.resume(returning: nil)
        }
        channels[id] = nil
    }

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
        guard count > 0 else { return }
        record.retained.removeFirst(count)
        record.retainedBytes -= released
        let credit = record.creditWaiters.values
        record.creditWaiters.removeAll()
        var flush: [CheckedContinuation<Void, any Error>] = []
        if record.retained.isEmpty {
            flush = Array(record.flushWaiters.values)
            record.flushWaiters.removeAll()
        }
        channels[id] = record
        for waiter in credit { waiter.resume() }
        for waiter in flush { waiter.resume() }
    }

    // MARK: - Consumer

    func channelNextEvent(_ id: UInt32) async -> ChannelEvent? {
        guard var record = channels[id] else { return nil }
        if let event = record.popEvent() {
            channels[id] = record
            consumed(id, event)
            return event
        }
        guard !record.finished, record.consumerWaiter == nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ChannelEvent?, Never>) in
                if Task.isCancelled || channels[id] == nil {
                    continuation.resume(returning: nil)
                } else {
                    channels[id]?.consumerWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelConsumer(id) }
        }
    }

    func cancelConsumer(_ id: UInt32) {
        guard let waiter = channels[id]?.consumerWaiter else { return }
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
            removeIfDone(id)
        }
    }

    func markAck(_ id: UInt32) {
        guard current != nil else { return }
        outbound.markAck(id)
        wakePump()
    }
}
