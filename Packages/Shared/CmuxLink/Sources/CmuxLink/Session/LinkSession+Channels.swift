import Foundation

/// Channel operations for features: open, send, flush, close, lifecycle.
extension LinkSession {
    // MARK: - Open

    public func openChannel(_ descriptor: ChannelDescriptor, resumeFrom cursor: StreamCursor?) throws -> LinkChannel {
        if case let .closed(reason) = machine.state { throw LinkError.closed(reason) }
        guard channels.count < configuration.maxChannels else {
            throw LinkError.capacityExceeded(resource: "channels", limit: configuration.maxChannels)
        }
        let id = nextChannelID
        nextChannelID &+= 2
        let record = makeRecord(
            id: id, descriptor: descriptor, openedLocally: true,
            cursorEpoch: cursor?.epoch ?? epoch, lastReceived: cursor?.revision ?? 0
        )
        channels[id] = record
        if current != nil, pendingDial == nil, machine.state.isLive {
            enqueueOpen(id)
        }
        return LinkChannel(id: id, incarnation: record.incarnation, descriptor: descriptor, session: self)
    }

    func makeRecord(
        id: UInt32, descriptor: ChannelDescriptor, openedLocally: Bool, cursorEpoch: UInt64, lastReceived: UInt64
    ) -> ChannelRecord {
        let incarnation = nextIncarnation
        nextIncarnation += 1
        return ChannelRecord(
            id: id, incarnation: incarnation, descriptor: descriptor, openedLocally: openedLocally,
            cursorEpoch: cursorEpoch, lastReceived: lastReceived
        )
    }

    /// Whether `id` still names the channel a handle was created for.
    func isLive(_ id: UInt32, _ incarnation: UInt64) -> Bool {
        channels[id]?.incarnation == incarnation
    }

    /// Re-declares channels on a fresh transport. The opener sends `open`
    /// with its consumed cursor (locally closed channels too, so retained
    /// data replays before their close); the other side waits for it. A
    /// non-opener that closed retires: if the opener still holds the
    /// channel, its `open` is answered with `close`.
    func redeclareChannels() {
        for id in channels.keys.sorted() {
            guard var record = channels[id] else { continue }
            record.phase = .awaiting
            record.closeQueued = false
            record.stalled = false
            channels[id] = record
            if record.localClosed && record.remoteClosed {
                retire(id)
            } else if record.openedLocally && !record.remoteClosed {
                enqueueOpen(id)
            } else if record.localClosed {
                retire(id)
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
            cursorEpoch: record.cursorEpoch, cursorRevision: record.lastConsumed
        ))
    }

    /// Channel-scoped control frames ride the channel's reliable lane at its
    /// priority, so carriers that map lanes to separate streams keep them in
    /// order with the channel's reliable data.
    func enqueueChannelControl(_ id: UInt32, frame: LinkFrame) {
        let priority = channels[id]?.sendPriority ?? .control
        let lane = TransportLane(reliability: .reliableOrdered, priority: priority)
        let item = OutboundItem(frame: frame, lane: lane, bytes: 32, enqueuedAt: clock.now)
        switch frame {
        case .close:
            outbound.enqueue(item, priority: priority)
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
            guard id > highestPeerChannelID else {
                // Closed earlier in this epoch: let the opener finish its close.
                enqueueChannelControl(id, frame: .close(channel: id))
                return
            }
            guard channels.count < configuration.maxChannels else {
                highestPeerChannelID = id
                enqueueChannelControl(id, frame: .close(channel: id))
                return
            }
            highestPeerChannelID = id
            let record = makeRecord(
                id: id, descriptor: descriptor, openedLocally: false, cursorEpoch: epoch, lastReceived: 0
            )
            channels[id] = record
            deliverIncoming(LinkChannel(id: id, incarnation: record.incarnation, descriptor: descriptor, session: self))
        }
        guard var record = channels[id] else { return }
        guard !record.remoteClosed else {
            enqueueChannelControl(id, frame: .close(channel: id))
            return
        }
        record.phase = .open
        record.everOpened = true
        channels[id] = record
        enqueueChannelControl(id, frame: .openAck(channel: id, epoch: epoch, revision: record.lastConsumed))
        channelBecameOpen(id, peerEpoch: cursorEpoch, peerRevision: cursorRevision)
    }

    /// Refuses an incoming channel whose handle could not be delivered to the
    /// feature consumer. The record is removed immediately, so repeated opens
    /// cannot accumulate retired handles while the peer is slow or malicious.
    func rejectIncomingChannel(_ channel: LinkChannel) {
        guard let record = channels.removeValue(forKey: channel.id), record.incarnation == channel.incarnation else { return }
        enqueueChannelControl(channel.id, frame: .close(channel: channel.id))
    }

    func peerAcknowledgedOpen(_ id: UInt32, revision: UInt64) {
        guard var record = channels[id], record.openedLocally, !record.remoteClosed else { return }
        record.phase = .open
        record.everOpened = true
        channels[id] = record
        channelBecameOpen(id, peerEpoch: epoch, peerRevision: revision)
    }

    // MARK: - Send

    /// The default terminal render window follows the measured path RTT. A
    /// feature that supplies a non-default budget keeps that contract; this
    /// avoids silently changing small diagnostic channels and keeps the
    /// adaptation bounded by `LinkConfiguration`.
    func effectiveBudget(for record: ChannelRecord) -> Int {
        let base = record.sendBudgetOverride ?? record.descriptor.budgetBytes
        guard record.descriptor.reliability == .reliableOrdered,
              record.sendPriority == .render,
              record.descriptor.priority == .render || record.sendBudgetOverride != nil,
              base == ChannelDescriptor.defaultBudget(for: .render)
        else { return base }
        return configuration.renderCreditBudget(for: rtt, base: base)
    }

    func channelSend(_ id: UInt32, _ incarnation: UInt64, _ payload: Data) async throws -> UInt64 {
        let size = payload.count
        let limit = min(configuration.maxFrameBytes, current?.capabilities.maxFrameBytes ?? .max)
        guard size + LinkFrame.dataOverhead <= limit else {
            throw LinkError.messageTooLarge(size: size, limit: limit - LinkFrame.dataOverhead)
        }
        try checkSendable(id, incarnation)
        guard let descriptor = channels[id]?.descriptor else { throw LinkError.channelClosed }
        if descriptor.reliability.isReliable {
            while let record = channels[id], record.retainedBytes > 0,
                  record.retainedBytes + size > effectiveBudget(for: record) {
                try await waitForCredit(id)
                try checkSendable(id, incarnation)
            }
            guard var record = channels[id] else { throw LinkError.channelClosed }
            let revision = record.nextRevision
            record.nextRevision += 1
            record.retained.append(LinkMessage(revision: revision, payload: payload))
            record.retainedBytes += size
            channels[id] = record
            if record.phase == .open, !record.stalled {
                enqueueData(id, revision: revision, payload: payload)
            }
            return revision
        }
        guard var record = channels[id] else { throw LinkError.channelClosed }
        let revision = record.nextRevision
        record.nextRevision += 1
        channels[id] = record
        if record.phase == .open {
            enqueueData(id, revision: revision, payload: payload)
        }
        return revision
    }

    func checkSendable(_ id: UInt32, _ incarnation: UInt64) throws {
        if case let .closed(reason) = machine.state { throw LinkError.closed(reason) }
        guard isLive(id, incarnation), let record = channels[id], !record.isClosed else {
            throw LinkError.channelClosed
        }
        if let current, record.descriptor.priority == .bulk, !current.capabilities.carriesBulk {
            throw LinkError.unsupportedOnPath(current.path.kind)
        }
    }

    /// Queues one data frame on the current transport. Returns false when
    /// the path cannot carry it (bulk on a control-sized path, or a frame
    /// above the path's limit after a path change); reliable channels then
    /// stall until a capable path, so order is kept.
    @discardableResult
    func enqueueData(_ id: UInt32, revision: UInt64, payload: Data) -> Bool {
        guard var record = channels[id], let current else { return false }
        let descriptor = record.descriptor
        let fits = payload.count + LinkFrame.dataOverhead <= current.capabilities.maxFrameBytes
        guard fits, descriptor.priority != .bulk || current.capabilities.carriesBulk else {
            if descriptor.reliability.isReliable {
                channels[id]?.stalled = true
            }
            return false
        }
        let priority = record.sendPriority
        let lane = TransportLane(reliability: descriptor.reliability, priority: priority)
        var item = OutboundItem(
            frame: .data(channel: id, revision: revision, payload: payload),
            lane: lane, bytes: payload.count, enqueuedAt: clock.now
        )
        if !descriptor.reliability.isReliable {
            item.budgetChannel = id
            if case let .partial(lifetime) = descriptor.reliability { item.lifetime = lifetime }
            while record.queuedBytes > 0, record.queuedBytes + payload.count > descriptor.budgetBytes,
                  let dropped = outbound.dropOldest(channel: id, priority: priority) {
                record.queuedBytes -= dropped
            }
            record.queuedBytes += payload.count
            channels[id] = record
        }
        outbound.enqueue(item, priority: priority)
        wakePump()
        return true
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

    /// Wakes senders after retained bytes dropped, and flushers when nothing
    /// is retained.
    func releaseCredit(_ id: UInt32) {
        guard var record = channels[id] else { return }
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

    func channelFlush(_ id: UInt32, _ incarnation: UInt64) async throws {
        if case let .closed(reason) = machine.state { throw LinkError.closed(reason) }
        guard isLive(id, incarnation), let record = channels[id], !record.retained.isEmpty else { return }
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

    func channelSetSendPriority(_ id: UInt32, _ incarnation: UInt64, _ priority: ChannelPriority,
                                budgetBytes: Int? = nil) {
        guard isLive(id, incarnation) else { return }
        channels[id]?.sendPriority = priority
        channels[id]?.sendBudgetOverride = budgetBytes.map { max(1, $0) }
    }

    func channelCursor(_ id: UInt32, _ incarnation: UInt64, stream: String) -> StreamCursor {
        let record = isLive(id, incarnation) ? channels[id] : retired[incarnation]
        return StreamCursor(stream: stream, epoch: record?.cursorEpoch ?? epoch, revision: record?.lastConsumed ?? 0)
    }

    // MARK: - Close

    func channelClose(_ id: UInt32, _ incarnation: UInt64) {
        guard isLive(id, incarnation), var record = channels[id], !record.localClosed else { return }
        record.localClosed = true
        channels[id] = record
        failWaiters(id, error: LinkError.channelClosed)
        if record.remoteClosed {
            retire(id)
            return
        }
        channels[id]?.clearInbox()
        deliver(id, .closed(.local))
        if record.phase == .open, current != nil {
            // FIFO behind this channel's queued data at its priority.
            channels[id]?.closeQueued = true
            enqueueChannelControl(id, frame: .close(channel: id))
        } else if !record.openedLocally {
            // The opener's next `open` is answered with close.
            retire(id)
        }
        // Otherwise the close follows the next open handshake.
    }

    func receiveClose(_ id: UInt32) {
        guard var record = channels[id] else { return }
        if record.localClosed {
            record.remoteClosed = true
            channels[id] = record
            retire(id)
            return
        }
        record.remoteClosed = true
        record.localClosed = true
        channels[id] = record
        failWaiters(id, error: LinkError.channelClosed)
        deliver(id, .closed(.remote))
        enqueueChannelControl(id, frame: .close(channel: id))
        retire(id)
    }

    /// Ends a channel when the session closes or its epoch is gone.
    func endChannel(_ id: UInt32, reason: ChannelCloseReason, error: any Error) {
        guard var record = channels[id] else { return }
        let wasClosed = record.isClosed
        record.localClosed = true
        record.remoteClosed = true
        channels[id] = record
        failWaiters(id, error: error)
        if !wasClosed { deliver(id, .closed(reason)) }
        retire(id)
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

    /// Frees the wire id. Undelivered events (ending in `.closed`) stay
    /// readable through the channel's incarnation; retained payloads go.
    func retire(_ id: UInt32) {
        guard var record = channels.removeValue(forKey: id) else { return }
        let credit = record.creditWaiters.values
        let flush = record.flushWaiters.values
        record.creditWaiters.removeAll()
        record.flushWaiters.removeAll()
        record.dropRetained()
        for waiter in credit { waiter.resume(throwing: LinkError.channelClosed) }
        for waiter in flush { waiter.resume(throwing: LinkError.channelClosed) }
        if record.finished { return }
        guard record.hasPendingEvents else {
            if let waiter = record.consumerWaiter { waiter.resume(returning: nil) }
            return
        }
        retired[record.incarnation] = record
    }
}
