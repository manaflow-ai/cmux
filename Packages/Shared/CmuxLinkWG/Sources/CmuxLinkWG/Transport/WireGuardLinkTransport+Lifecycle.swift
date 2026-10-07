import CmuxLink
import Foundation

extension WireGuardLinkTransport {
    // MARK: Underlay

    /// Makes `underlay` current and returns the token its events must carry.
    func attach(_ underlay: any DatagramUnderlay, path: PathKind) -> UInt64 {
        underlayToken += 1
        self.underlay = underlay
        currentPath = path
        maxDatagramBytes = max(WireGuardProtocol.minimumDataLength + 128, underlay.maxDatagramBytes)
        rebindDeadline = nil
        wakePump()
        return underlayToken
    }

    /// Dialer: attaches an underlay and reads it.
    func attachAndRead(_ underlay: any DatagramUnderlay) async {
        let path = await underlay.path
        let token = attach(underlay, path: path)
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            for await event in underlay.events {
                guard let self else { return }
                await self.underlayEvent(event, token: token)
            }
        }
    }

    /// Host: an underlay whose first datagram claims one of this tunnel's
    /// indices. Adopted only when that datagram authenticates and is fresh,
    /// so a replayed packet cannot steal the session's path.
    func adopt(_ underlay: any DatagramUnderlay, firstDatagram: Data) async -> UInt64? {
        guard phase == .open || phase == .handshaking else { return nil }
        let output = tunnel.decapsulate([UInt8](firstDatagram), now: clock.now)
        guard output.error == nil, output.plaintext != nil else { return nil }
        let path = await underlay.path
        guard phase == .open || phase == .handshaking else { return nil }
        let previous = self.underlay
        let token = attach(underlay, path: path)
        apply(output)
        requeueUnacknowledged()
        emit(.pathChanged(self.path))
        rearmTimer()
        if let previous { Task { await previous.close() } }
        return token
    }

    func underlayClosed(_ reason: UnderlayCloseReason) async {
        switch phase {
        case .closed:
            return
        case .closing:
            finish(.local)
            return
        case .handshaking:
            failHandshake()
            return
        case .open:
            break
        }
        switch reason {
        case .local:
            return
        case .reset:
            finish(.pathLost("peer reset the underlay"))
        case let .pathLost(detail):
            guard tunnel.hasUsableSession(at: clock.now) else {
                finish(.pathLost(detail))
                return
            }
            underlay = nil
            rebindDeadline = clock.now + configuration.rebindWindow
            rearmTimer()
            if case let .dialer(underlays, peer) = role {
                rebindTask?.cancel()
                rebindTask = Task { [weak self] in await self?.rebind(underlays, peer: peer) }
            }
        }
    }

    /// Dialer roaming: open a new underlay and keep the WireGuard session.
    private func rebind(_ underlays: any DatagramUnderlayDialer, peer: LinkPeer) async {
        var delay = Duration.milliseconds(10)
        while phase == .open, underlay == nil, let deadline = rebindDeadline, clock.now < deadline {
            do {
                let next = try await underlays.open(to: peer)
                guard phase == .open, underlay == nil else {
                    await next.close()
                    return
                }
                await attachAndRead(next)
                // One packet under the current keys lets the host route the
                // new underlay to this session.
                apply(tunnel.encapsulate([], now: clock.now))
                requeueUnacknowledged()
                emit(.pathChanged(path))
                wakePump()
                rearmTimer()
                return
            } catch {
                do { try await clock.sleep(for: delay) } catch { return }
                delay = min(delay * 2, .seconds(1))
            }
        }
    }

    /// After an underlay change, everything unacknowledged goes again at
    /// once instead of waiting for its RTO.
    func requeueUnacknowledged() {
        for lane in Array(senders.keys) {
            guard var sender = senders[lane] else { continue }
            let seqs = sender.requeueAll()
            senders[lane] = sender
            guard !seqs.isEmpty else { continue }
            var queue = reliableQueues[lane] ?? LaneFIFO()
            for seq in seqs { queue.push(seq) }
            reliableQueues[lane] = queue
        }
        wakePump()
    }

    // MARK: Handshake

    /// Dialer: runs the WireGuard handshake on the attached underlay.
    func connect() async throws {
        connectDeadline = clock.now + configuration.connectTimeout
        apply(tunnel.beginHandshake(now: clock.now))
        rearmTimer()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                switch phase {
                case .open: continuation.resume()
                case .handshaking: handshakeWaiter = continuation
                case .closing, .closed: continuation.resume(throwing: WireGuardCarrierError.closed)
                }
            }
        } onCancel: {
            Task { await self.cancelConnect() }
        }
    }

    /// Host: answers the initiation that created this transport.
    func answer(_ initiation: WireGuardReceivedInitiation) {
        connectDeadline = clock.now + configuration.connectTimeout
        apply(tunnel.respond(to: initiation, now: clock.now))
        rearmTimer()
    }

    func cancelConnect() {
        guard phase == .handshaking else { return }
        handshakeWaiter?.resume(throwing: CancellationError())
        handshakeWaiter = nil
        finish(.local)
    }

    func failHandshake() {
        handshakeWaiter?.resume(throwing: WireGuardCarrierError.handshakeTimeout)
        handshakeWaiter = nil
        finish(.pathLost("WireGuard handshake did not complete"))
    }

    // MARK: Close

    public func close() async {
        switch phase {
        case .closed:
            return
        case .handshaking:
            finish(.local)
            return
        case .closing:
            await waitClosed()
            return
        case .open:
            break
        }
        phase = .closing
        closeDeadline = clock.now + configuration.closeTimeout
        let waiters = windowWaiters.values
        windowWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: WireGuardCarrierError.closed) }
        rearmTimer()
        if !allLanesDrained {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                drainWaiter = continuation
            }
        }
        guard phase == .closing else {
            await waitClosed()
            return
        }
        guard underlay != nil else {
            finish(.local)
            return
        }
        controlQueue.push(.close)
        closeSentAt = clock.now
        wakePump()
        rearmTimer()
        await waitClosed()
    }

    private func waitClosed() async {
        guard phase != .closed else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closedWaiters.append(continuation)
        }
    }

    /// Ends the transport once: emits `.closed`, fails waiters, closes the
    /// underlay and stops every task.
    func finish(_ reason: TransportCloseReason) {
        guard phase != .closed else { return }
        phase = .closed
        eventSink.yield(.closed(reason))
        eventSink.finish()
        failAllWaiters()
        let closed = closedWaiters
        closedWaiters.removeAll()
        for waiter in closed { waiter.resume() }
        timerTask?.cancel()
        timerTask = nil
        rebindTask?.cancel()
        readerTask?.cancel()
        wakePump()
        let underlay = self.underlay
        self.underlay = nil
        let onClosed = self.onClosed
        Task {
            await underlay?.close()
            await onClosed?(self)
        }
    }
}

extension WireGuardLinkTransport {
    func ownsIndex(_ index: UInt32) -> Bool {
        tunnel.localIndices.contains(index)
    }
}
