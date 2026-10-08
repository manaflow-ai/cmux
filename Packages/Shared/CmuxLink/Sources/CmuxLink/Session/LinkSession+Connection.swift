import Foundation

/// Dialing, the hello/welcome handshake, reconnect with backoff, path
/// upgrade (make-before-break) and transport events.
extension LinkSession {
    // MARK: - Dialer attempts

    func startAttempt() {
        guard case let .dialer(peer, selector) = role, !machine.state.isClosed, connectTask == nil else { return }
        connectToken += 1
        let token = connectToken
        connectTask = Task { [weak self] in
            do {
                let transport = try await selector.race(to: peer)
                await self?.raceSucceeded(transport, token: token)
            } catch {
                await self?.raceFailed("\(error)", token: token)
            }
        }
    }

    func startUpgrade() {
        guard case let .dialer(peer, selector) = role, let current, connectTask == nil, pendingDial == nil else {
            return
        }
        let threshold = selector.policy.rank(of: current.path.kind)
        guard selector.bestReachableRank < threshold else { return }
        connectToken += 1
        let token = connectToken
        connectTask = Task { [weak self] in
            do {
                let transport = try await selector.race(to: peer, betterThan: threshold)
                await self?.raceSucceeded(transport, token: token)
            } catch {
                await self?.raceFailed("upgrade: \(error)", token: token)
            }
        }
    }

    func scheduleUpgradeIfNeeded() {
        guard case let .dialer(_, selector) = role, let current, retryTask == nil,
              let delay = selector.policy.upgradeRetry,
              selector.bestReachableRank < selector.policy.rank(of: current.path.kind) else { return }
        let clock = clock
        retryTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.upgradeTimerFired()
        }
    }

    func upgradeTimerFired() {
        retryTask = nil
        startUpgrade()
    }

    /// Cancels the in-flight race; its completion is ignored.
    func cancelConnectTask() {
        connectTask?.cancel()
        connectTask = nil
        connectToken += 1
    }

    func raceFailed(_ message: String, token: UInt64) {
        guard token == connectToken else { return }
        connectTask = nil
        attemptFailed(message)
    }

    func raceSucceeded(_ transport: any LinkTransport, token: UInt64) async {
        guard token == connectToken else {
            closeTransportLater(transport)
            return
        }
        connectTask = nil
        guard !machine.state.isClosed, pendingDial == nil else {
            closeTransportLater(transport)
            return
        }
        let attached = Attached(
            generation: nextGeneration,
            transport: transport,
            path: await transport.path,
            capabilities: transport.capabilities
        )
        nextGeneration += 1
        guard !machine.state.isClosed, pendingDial == nil else {
            closeTransportLater(transport)
            return
        }
        pendingDial = attached
        startReader(attached)
        let hello = LinkFrame.hello(sessionID: sessionID, epoch: epoch)
        let generation = attached.generation
        let clock = clock
        let timeout = configuration.handshakeTimeout
        handshakeTask = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.handshakeTimedOut(generation)
        }
        do {
            try await transport.send(TransportFrame(lane: .control, bytes: hello.encoded()))
        } catch {
            dialFailed(generation, "hello: \(error)")
        }
    }

    nonisolated func startReader(_ attached: Attached) {
        let generation = attached.generation
        let events = attached.transport.events
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event, generation: generation)
            }
        }
    }

    func handshakeTimedOut(_ generation: UInt64) {
        dialFailed(generation, "handshake timeout")
    }

    /// A pending dial ended before `welcome`.
    func dialFailed(_ generation: UInt64, _ message: String) {
        guard let pending = pendingDial, pending.generation == generation else { return }
        pendingDial = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        closeTransportLater(pending.transport)
        attemptFailed(message)
    }

    func attemptFailed(_ message: String) {
        guard !machine.state.isClosed else { return }
        if current != nil {
            // A failed upgrade keeps the live path.
            scheduleUpgradeIfNeeded()
            return
        }
        if machine.state.isLive {
            // The old transport died while an upgrade was pending, and the
            // upgrade failed too: this is a transport loss.
            attempt = 1
            apply(.transportLost(attempt: 1))
            startAttempt()
            return
        }
        attempt += 1
        guard attempt <= configuration.maxConnectAttempts else {
            finish(.unreachable(attempts: attempt - 1), notifyPeer: false)
            return
        }
        apply(.attemptStarted(attempt))
        let delay = configuration.backoff.delay(after: attempt - 1)
        let clock = clock
        retryTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.retryFired()
        }
    }

    func retryFired() {
        retryTask = nil
        startAttempt()
    }

    // MARK: - Handshake completion

    /// Dialer: `welcome` arrived on the pending transport.
    func completeDial(epoch newEpoch: UInt64, resumed: Bool) {
        guard let attached = pendingDial else { return }
        pendingDial = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        if !resumed, epoch != 0 { resetForNewEpoch() }
        epoch = newEpoch
        // Channels with nothing received yet count from the session's epoch.
        for (id, record) in channels where record.lastReceived == 0 && record.cursorEpoch != newEpoch {
            channels[id]?.cursorEpoch = newEpoch
        }
        retryTask?.cancel()
        retryTask = nil
        switchTransport(to: attached)
        redeclareChannels()
        attempt = 0
        apply(.connected(attached.path))
        publishBadge()
        scheduleUpgradeIfNeeded()
    }

    /// Accepted side: `LinkHost` routed a dialer's `hello` here. Returns the
    /// generation the host tags this transport's events with.
    func attachAccepted(_ transport: any LinkTransport, resumed: Bool) async -> UInt64 {
        let path = await transport.path
        let attached = Attached(
            generation: nextGeneration, transport: transport, path: path, capabilities: transport.capabilities
        )
        nextGeneration += 1
        guard !machine.state.isClosed else {
            closeTransportLater(transport)
            return attached.generation
        }
        ensurePump()
        resumeWindowTask?.cancel()
        resumeWindowTask = nil
        switchTransport(to: attached)
        outbound.enqueueControl(OutboundItem(
            frame: .welcome(epoch: epoch, resumed: resumed), lane: .control, bytes: 11, enqueuedAt: clock.now
        ))
        redeclareChannels()
        apply(.connected(path))
        publishBadge()
        wakePump()
        return attached.generation
    }

    /// Makes `attached` the transport the pump sends on. Frames queued for
    /// the old transport are dropped; retention covers reliable ones.
    func switchTransport(to attached: Attached) {
        if let old = current, old.generation != attached.generation {
            closeTransportLater(old.transport)
        }
        current = attached
        if case .dialer = role {
            authenticatedPeer = attached.transport.peerIdentity
        } else if authenticatedPeer == nil {
            authenticatedPeer = attached.transport.peerIdentity
        }
        rtt = nil
        outbound.removeAll()
        for id in channels.keys { channels[id]?.queuedBytes = 0 }
        wakePump()
    }

    // MARK: - Transport events

    func handle(_ event: TransportEvent, generation: UInt64) {
        switch event {
        case let .frame(frame):
            guard current?.generation == generation || pendingDial?.generation == generation else { return }
            let decoded: LinkFrame
            do {
                decoded = try LinkFrame(decoding: frame.bytes)
            } catch {
                finish(.protocolViolation("\(error)"), notifyPeer: true)
                return
            }
            handleFrame(decoded, generation: generation)
        case let .pathChanged(path):
            guard current?.generation == generation else { return }
            current?.path = path
            apply(.pathChanged(path))
            publishBadge()
            if retryTask == nil { scheduleUpgradeIfNeeded() }
        case let .rtt(sample):
            guard current?.generation == generation else { return }
            rtt = sample
            wakeRenderCreditWaiters()
            publishBadge()
            if let threshold = configuration.degradedRTT {
                if sample > threshold {
                    apply(.health(.degraded(.highLatency)))
                } else if case .degraded(_, .highLatency) = machine.state {
                    apply(.health(.good))
                }
            }
        case let .health(health):
            guard current?.generation == generation else { return }
            apply(.health(health))
        case let .mediaTrack(track):
            guard current?.generation == generation else { return }
            deliverIncoming(track)
        case .closed:
            transportClosed(generation)
        }
    }

    /// An RTT increase can enlarge the adaptive render window without an
    /// acknowledgement arriving first. Wake only render senders; their
    /// `channelSend` loop re-checks the bounded budget before proceeding.
    func wakeRenderCreditWaiters() {
        guard configuration.renderCreditTargetBytesPerSecond != nil else { return }
        for id in channels.keys {
            guard let record = channels[id],
                  record.descriptor.reliability == .reliableOrdered,
                  record.descriptor.priority == .render,
                  record.descriptor.budgetBytes == ChannelDescriptor.defaultBudget(for: .render)
            else { continue }
            let waiters = Array(record.creditWaiters.values)
            channels[id]?.creditWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func handleFrame(_ frame: LinkFrame, generation: UInt64) {
        switch frame {
        case let .welcome(newEpoch, resumed):
            guard isDialer, pendingDial?.generation == generation else { return }
            completeDial(epoch: newEpoch, resumed: resumed)
        case .hello:
            return
        case let .open(channel, descriptor, cursorEpoch, cursorRevision):
            peerOpened(channel, descriptor: descriptor, cursorEpoch: cursorEpoch, cursorRevision: cursorRevision)
        case let .openAck(channel, _, revision):
            peerAcknowledgedOpen(channel, revision: revision)
        case let .data(channel, revision, payload):
            receiveData(channel, revision: revision, payload: payload)
        case let .ack(channel, revision):
            receiveAck(channel, revision: revision)
        case let .close(channel):
            receiveClose(channel)
        case let .gap(channel, resumeAfter, reason):
            receiveGap(channel, resumeAfter: resumeAfter, reason: reason)
        case let .sessionClose(code):
            let reason: LinkCloseReason = switch code {
            case .normal: .remote
            case .unauthorized: .unauthorized
            case .protocolViolation: .protocolViolation("peer reported a protocol violation")
            }
            finish(reason, notifyPeer: false)
        }
    }

    func transportClosed(_ generation: UInt64) {
        if pendingDial?.generation == generation {
            dialFailed(generation, "transport closed during handshake")
            return
        }
        guard let lost = current, lost.generation == generation else { return }
        current = nil
        rtt = nil
        outbound.removeAll()
        for id in channels.keys {
            channels[id]?.queuedBytes = 0
            if channels[id]?.phase == .open { channels[id]?.phase = .awaiting }
        }
        guard !machine.state.isClosed else { return }
        switch role {
        case .dialer:
            if pendingDial != nil {
                // Make-before-break: the peer closed the old transport after
                // it took the new one. `welcome` or the dial's failure decides.
                return
            }
            cancelConnectTask()
            retryTask?.cancel()
            retryTask = nil
            attempt = 1
            apply(.transportLost(attempt: 1))
            startAttempt()
        case .accepted:
            apply(.transportLost(attempt: 0))
            let clock = clock
            let window = configuration.resumeWindow
            resumeWindowTask = Task { [weak self] in
                do { try await clock.sleep(for: window) } catch { return }
                await self?.resumeWindowExpired()
            }
        }
    }

    func resumeWindowExpired() {
        resumeWindowTask = nil
        guard current == nil else { return }
        finish(.unreachable(attempts: 0), notifyPeer: false)
    }
}
