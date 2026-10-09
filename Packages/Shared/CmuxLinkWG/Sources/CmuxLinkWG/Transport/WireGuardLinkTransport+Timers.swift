import CmuxLink

extension WireGuardLinkTransport {
    /// Arms the one timer for the earliest pending deadline. A later
    /// deadline does not re-arm: the armed one fires and recomputes. With
    /// nothing pending nothing is armed (an idle transport never wakes).
    func rearmTimer() {
        guard phase != .closed else { return }
        guard let deadline = nextDeadline() else { return }
        if let armedDeadline, armedDeadline <= deadline { return }
        timerTask?.cancel()
        armedDeadline = deadline
        let delay = max(.zero, deadline - clock.now)
        let clock = self.clock
        timerTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.timerFired(deadline)
        }
    }

    func nextDeadline() -> Duration? {
        var deadlines: [Duration] = []
        if let deadline = tunnel.nextDeadline() { deadlines.append(deadline) }
        let timeout = retransmit.timeout
        for sender in senders.values {
            if let deadline = sender.earliestDeadline(timeout: timeout) { deadlines.append(deadline) }
            if let oldest = sender.oldestSend() { deadlines.append(oldest + configuration.deadPathTimeout) }
        }
        if let connectDeadline { deadlines.append(connectDeadline) }
        if let rebindDeadline { deadlines.append(rebindDeadline) }
        if let closeDeadline { deadlines.append(closeDeadline) }
        if let closeSentAt { deadlines.append(closeSentAt + timeout) }
        return deadlines.min()
    }

    func timerFired(_ deadline: Duration) {
        guard armedDeadline == deadline, phase != .closed else { return }
        armedDeadline = nil
        timerTask = nil
        let now = clock.now

        apply(tunnel.updateTimers(now: now))
        if phase == .closed { return }

        if let connectDeadline, now >= connectDeadline, phase == .handshaking {
            failHandshake()
            return
        }
        if let rebindDeadline, now >= rebindDeadline, underlay == nil {
            finish(.pathLost("no underlay within the rebind window"))
            return
        }
        if let closeDeadline, now >= closeDeadline, phase == .closing {
            finish(.local)
            return
        }

        let timeout = retransmit.timeout
        var timedOut = false
        for lane in Array(senders.keys) {
            guard var sender = senders[lane] else { continue }
            if let oldest = sender.oldestSend(), now - oldest >= configuration.deadPathTimeout {
                finish(.pathLost("unacknowledged for \(configuration.deadPathTimeout)"))
                return
            }
            let expired = sender.expired(now: now, timeout: timeout)
            senders[lane] = sender
            guard !expired.isEmpty else { continue }
            timedOut = true
            var queue = reliableQueues[lane] ?? LaneFIFO()
            for seq in expired { queue.push(seq) }
            reliableQueues[lane] = queue
        }
        if timedOut {
            retransmit.timedOut()
            wakePump()
        }
        if let closeSentAt, now >= closeSentAt + timeout, phase == .closing {
            controlQueue.push(.close)
            self.closeSentAt = now
            wakePump()
        }
        rearmTimer()
    }
}
