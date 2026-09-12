import Foundation
import IrohLib

extension IrohPeerConnection {
    func runAcceptLoop() async {
        while true {
            do {
                let stream = try await connection.acceptBi()
                guard !Task.isCancelled, !closedFlag else {
                    await closeUnadoptedStream(stream)
                    return
                }
                guard inboundStreamTasks.count < Self.maxConcurrentInboundStreams else {
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.error(
                            """
                            conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                            inbound stream limit reached (\(Self.maxConcurrentInboundStreams, privacy: .public)); rejecting
                            """)
                    }
                    await closeUnadoptedStream(stream)
                    continue
                }
                inboundStreamCounter &+= 1
                let taskID = inboundStreamCounter
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.processInboundStream(stream, taskID: taskID)
                }
                inboundStreamTasks[taskID] = task
            } catch {
                // Connection died (or closed): every waiter gets a dead lane
                // that EOFs immediately; in-flight lane bytes die with the
                // session (contract 5.4).
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        conn \(TransportDebugLog.id(self), privacy: .public) accept-loop exit \
                        cause=\(String(describing: error), privacy: .public) \
                        remote=\(TransportDebugLog.hex8(self.remoteKey), privacy: .public)
                        """)
                }
                await finishClosure(reason: nil, locallyInitiated: false)
                return
            }
        }
    }

    /// Handles one stream independently of the accept loop. A peer that opens
    /// a stream and never sends its preamble therefore consumes only one
    /// bounded worker and cannot block later control/application lanes.
    func processInboundStream(_ stream: BiStream, taskID: UInt64) async {
        defer { inboundStreamTasks.removeValue(forKey: taskID) }
        let channel = IrohLaneChannel(
            send: stream.send(), recv: stream.recv(),
            onProtocolError: { [weak self] in
                await self?.protocolViolation()
            })
        guard let open = await receiveOpenFrameWithDeadline(channel: channel),
            !closedFlag, !Task.isCancelled
        else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    inbound stream EOF/deadline before open frame; skipped
                    """)
            }
            await closeUnadoptedStream(stream)
            return
        }

        // Raw application streams (graduation bridge): after the one
        // handshake frame the stream is unframed bytes, handed whole to the
        // registered owner. `receiveOpenFrame` intentionally leaves all
        // coalesced bytes in the decoder remainder.
        if open.type == Self.rawOpenType {
            let preamble = open.payload["preamble"]?.stringValue ?? ""
            let raw = RawByteStream(
                send: stream.send(), recv: stream.recv(),
                buffered: await channel.drainBufferedBytes())
            guard !closedFlag, !Task.isCancelled else {
                await closeUnadoptedStream(stream)
                return
            }
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    inbound raw stream preamble=\(preamble, privacy: .public) \
                    delivery=\(self.rawStreamHandler != nil ? "handler" : "pending", privacy: .public) \
                    remainderBytes=\(raw.handshakeRemainder.count, privacy: .public)
                    """)
            }
            if rawStreamHandler != nil {
                guard rawDeliveryQueue.count - rawDeliveryHead < Self.maxConcurrentInboundStreams else {
                    await raw.resetSend(errorCode: 1)
                    await raw.stopReceiving(errorCode: 1)
                    return
                }
                rawDeliveryQueue.append((preamble, raw))
                // Delivery is serialized through one FIFO task so the
                // handler observes streams in substrate arrival order.
                startRawDeliveryIfNeeded()
            } else {
                guard pendingRawStreams.count < Self.maxConcurrentInboundStreams else {
                    await raw.resetSend(errorCode: 1)
                    await raw.stopReceiving(errorCode: 1)
                    return
                }
                pendingRawStreams.append((preamble, raw))
            }
            return
        }

        guard open.type == Self.laneOpenType,
            let name = open.payload["name"]?.stringValue,
            !name.isEmpty,
            name.utf8.count <= 256
        else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    inbound stream with unexpected open frame type=\(open.type, privacy: .public); closing
                    """)
            }
            if !open.type.hasPrefix(FrameTypePolicy.optionalPrefix) {
                await closeAll(
                    reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
            }
            await closeUnadoptedStream(stream)
            return
        }
        guard lanes.count < Self.maxLaneCount else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    lane limit reached (\(Self.maxLaneCount, privacy: .public)); rejecting name=\(name, privacy: .public)
                    """)
            }
            await closeUnadoptedStream(stream)
            return
        }
        guard lanes[name] == nil else {
            // Keep the first stream as the lane's single source of truth;
            // accepting a duplicate would orphan the original consumer and
            // retain another live QUIC stream indefinitely.
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                    duplicate inbound lane name=\(name, privacy: .public); rejecting
                    """)
            }
            await closeUnadoptedStream(stream)
            return
        }

        let lane = makeLane(
            name: name,
            channel: channel)
        lanes[name] = lane
        let resumed = laneWaiters.removeValue(forKey: name) ?? []
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) accept-loop: \
                inbound lane name=\(name, privacy: .public) \
                waitersResumed=\(resumed.count, privacy: .public)
                """)
        }
        for waiter in resumed {
            laneWaiterTasks.removeValue(forKey: waiter.id)?.cancel()
            waiter.continuation.resume(returning: lane)
        }
    }

    /// Races the first-frame read against a genuine, cancellable deadline.
    /// On timeout, stopping the receive half is what wakes the FFI read; task
    /// cancellation alone is not sufficient for all iroh-ffi versions.
    private func receiveOpenFrameWithDeadline(channel: IrohLaneChannel) async -> Frame? {
        let sleep = handshakeSleep
        return await withTaskGroup(of: Frame?.self) { group in
            group.addTask { await channel.receiveOpenFrame() }
            group.addTask {
                do {
                    try await sleep(Self.inboundOpenDeadline)
                } catch {
                    return nil
                }
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            if result == nil {
                await channel.abortReceive()
            }
            await group.waitForAll()
            return result
        }
    }

    func closeUnadoptedStream(_ stream: BiStream) async {
        try? await stream.send().reset(errorCode: 1)
        try? await stream.recv().stop(errorCode: 1)
    }

    /// Closes the whole session when a framed lane cannot be decoded. A plain
    /// EOF would otherwise look like an ordinary transport loss to the
    /// reconnect owner and hide a protocol/version violation.
    func protocolViolation() async {
        guard !closedFlag else { return }
        await closeAll(
            reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
    }

    /// Starts the one FIFO raw-stream delivery worker, if a handler is ready.
    func startRawDeliveryIfNeeded() {
        guard rawDeliveryTask == nil, let handler = rawStreamHandler else { return }
        rawDeliveryTask = Task { [weak self] in
            while let self, let item = await self.nextRawDelivery() {
                await handler(item.0, item.1)
            }
            await self?.rawDeliveryFinished()
        }
    }

    /// Pops the next queued raw stream for the delivery worker.
    private func nextRawDelivery() -> (String, RawByteStream)? {
        guard rawDeliveryHead < rawDeliveryQueue.count else {
            rawDeliveryQueue.removeAll(keepingCapacity: true)
            rawDeliveryHead = 0
            return nil
        }
        let item = rawDeliveryQueue[rawDeliveryHead]
        rawDeliveryHead += 1
        // Compact only after a meaningful prefix has been consumed; this keeps
        // dequeue cost amortized O(1) without retaining old stream handles.
        if rawDeliveryHead >= 32, rawDeliveryHead * 2 >= rawDeliveryQueue.count {
            rawDeliveryQueue.removeSubrange(0..<rawDeliveryHead)
            rawDeliveryHead = 0
        }
        return item
    }

    /// Clears the completed worker handle; a later arrival can start a new one.
    private func rawDeliveryFinished() {
        rawDeliveryTask = nil
        if rawDeliveryHead < rawDeliveryQueue.count { startRawDeliveryIfNeeded() }
    }
}
