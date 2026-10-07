import CmuxLink
import Foundation

extension WireGuardLinkTransport {
    /// Every event of the current or a previous underlay.
    func underlayEvent(_ event: UnderlayEvent, token: UInt64) async {
        switch event {
        case let .datagram(data):
            receive([UInt8](data))
        case let .pathChanged(kind):
            guard token == underlayToken, phase != .closed else { return }
            currentPath = kind
            emit(.pathChanged(path))
        case let .closed(reason):
            guard token == underlayToken else { return }
            await underlayClosed(reason)
        }
    }

    func receive(_ datagram: [UInt8]) {
        guard phase != .closed else { return }
        let output = tunnel.decapsulate(datagram, now: clock.now)
        apply(output)
        rearmTimer()
    }

    func apply(_ output: WireGuardTunnelOutput) {
        for datagram in output.datagrams { rawQueue.push(datagram) }
        if !output.datagrams.isEmpty { wakePump() }
        if output.sessionEstablished { established() }
        if let plaintext = output.plaintext, !plaintext.isEmpty { receivePlaintext(plaintext) }
        if output.error == .handshakeTimeout {
            if phase == .handshaking {
                failHandshake()
            } else {
                finish(.pathLost("WireGuard handshake timed out"))
            }
        }
    }

    func established() {
        guard phase == .handshaking else { return }
        phase = .open
        connectDeadline = nil
        handshakeWaiter?.resume()
        handshakeWaiter = nil
        if let onEstablished {
            Task { await onEstablished(self) }
        }
    }

    private func receivePlaintext(_ plaintext: [UInt8]) {
        // Crypto-key routing: only the peer's overlay address, to ours, on
        // the lane port.
        guard let datagram = OverlayDatagram.decode(plaintext),
              datagram.source == remoteAddress, datagram.destination == localAddress,
              datagram.destinationPort == OverlayDatagram.laneServicePort,
              let frame = LaneFrame.decode(datagram.payload)
        else { return }
        switch frame {
        case let .reliable(lane, seq, first, last, payload):
            var receiver = receivers[lane] ?? ReliableReceiver(windowFragments: receiveWindowFragments)
            let frames = receiver.receive(seq: seq, first: first, last: last, payload: payload)
            receivers[lane] = receiver
            for bytes in frames {
                emit(.frame(TransportFrame(lane: transportLane(lane), bytes: Data(bytes))))
            }
            ackDirty.insert(lane)
            wakePump()
        case let .message(lane, id, index, count, lifetime, payload):
            var reassembler = reassemblers[lane] ?? MessageReassembler()
            let message = reassembler.receive(id: id, index: index, count: count, payload: payload)
            reassemblers[lane] = reassembler
            if let message {
                emit(.frame(TransportFrame(lane: transportLane(lane, lifetimeMillis: lifetime), bytes: Data(message))))
            }
        case let .ack(lane, next, sack):
            acknowledge(lane: lane, next: next, sack: sack)
        case .close:
            peerClosed()
        case .closeAck:
            if phase == .closing { finish(.local) }
        }
    }

    private func acknowledge(lane: LaneID, next: UInt32, sack: UInt64) {
        guard var sender = senders[lane] else { return }
        let result = sender.acknowledge(next: next, sack: sack, now: clock.now, smoothedRTT: retransmit.smoothed)
        senders[lane] = sender
        if let rtt = result.rtt {
            retransmit.sample(rtt)
            reportRTT()
        }
        if !result.retransmit.isEmpty {
            var queue = reliableQueues[lane] ?? LaneFIFO()
            for seq in result.retransmit { queue.push(seq) }
            reliableQueues[lane] = queue
            wakePump()
        }
        resumeWindowWaiters(for: lane)
        if phase == .closing, allLanesDrained {
            drainWaiter?.resume()
            drainWaiter = nil
        }
    }

    private func reportRTT() {
        guard let smoothed = retransmit.smoothed else { return }
        if let reported = reportedRTT {
            let change = smoothed > reported ? smoothed - reported : reported - smoothed
            guard change >= .milliseconds(1), change * 10 >= reported else { return }
        }
        reportedRTT = smoothed
        emit(.rtt(smoothed))
    }

    private func peerClosed() {
        guard phase == .open || phase == .closing else { return }
        let wasClosing = phase == .closing
        if let ack = seal(LaneFrame.closeAck.encode()), let underlay {
            let datagram = Data(ack)
            // Sent before the transport ends; the underlay closes after it.
            Task {
                try? await underlay.send(datagram)
                self.finish(wasClosing ? .local : .remote)
            }
            return
        }
        finish(wasClosing ? .local : .remote)
    }
}
