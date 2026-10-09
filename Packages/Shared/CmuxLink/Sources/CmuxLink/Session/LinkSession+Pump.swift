import Foundation

/// The single send pump: one frame at a time onto the current transport, in
/// `OutboundQueue` priority order. A carrier's `send` back-pressure stalls
/// only the pump, and the next frame chosen is always the most urgent.
extension LinkSession {
    func ensurePump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            while let self, let next = await self.nextOutbound() {
                await self.transmit(next)
            }
        }
    }

    struct Transmission: Sendable {
        let item: OutboundItem
        let attached: Attached
    }

    func nextOutbound() async -> Transmission? {
        while true {
            if let current, let item = dequeue() {
                return Transmission(item: item, attached: current)
            }
            if pumpFinished, current == nil || outbound.isEmpty {
                return nil
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pumpWaiter = continuation
            }
        }
    }

    func dequeue() -> OutboundItem? {
        let now = clock.now
        var expired: [OutboundItem] = []
        defer {
            for item in expired { releaseBudget(item) }
        }
        while let next = outbound.dequeue(now: now, expired: { expired.append($0) }) {
            switch next {
            case let .item(item):
                releaseBudget(item)
                return item
            case let .ack(channel):
                guard let record = channels[channel] else { continue }
                return OutboundItem(
                    frame: .ack(channel: channel, revision: record.lastConsumed),
                    lane: .control, bytes: 14, enqueuedAt: now
                )
            }
        }
        return nil
    }

    func releaseBudget(_ item: OutboundItem) {
        guard let channel = item.budgetChannel else { return }
        channels[channel]?.queuedBytes -= item.bytes
    }

    func transmit(_ transmission: Transmission) async {
        let item = transmission.item
        let transport = transmission.attached.transport
        do {
            try await transport.send(TransportFrame(lane: item.lane, bytes: item.frame.encoded()))
        } catch {
            // The transport is gone; its `.closed` event drives reconnect.
            if item.after == .none {
                closeTransportLater(transport)
                return
            }
        }
        if item.after == .closeTransport {
            if current?.generation == transmission.attached.generation { current = nil }
            await transport.close()
        }
    }

    func wakePump() {
        guard let waiter = pumpWaiter else { return }
        pumpWaiter = nil
        waiter.resume()
    }
}
