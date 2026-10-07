extension WireGuardLinkTransport {
    func waitForWindow(_ lane: LaneID, adding bytes: Int) async throws {
        while phase == .open {
            let inFlight = senders[lane]?.bytesInFlight ?? 0
            // An empty lane always takes one frame, however large.
            if inFlight == 0 || inFlight + bytes <= configuration.reliableWindowBytes { return }
            nextWaiterID += 1
            let id = nextWaiterID
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        windowWaiters[id] = (lane, continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancelWindowWaiter(id) }
            }
        }
    }

    func cancelWindowWaiter(_ id: UInt64) {
        windowWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    func resumeWindowWaiters(for lane: LaneID) {
        let ready = windowWaiters.filter { $0.value.lane == lane }
        for (id, waiter) in ready {
            windowWaiters[id] = nil
            waiter.continuation.resume()
        }
    }

    func failAllWaiters() {
        let waiters = windowWaiters.values
        windowWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: WireGuardCarrierError.closed) }
        handshakeWaiter?.resume(throwing: WireGuardCarrierError.closed)
        handshakeWaiter = nil
        drainWaiter?.resume()
        drainWaiter = nil
    }

    var allLanesDrained: Bool {
        senders.values.allSatisfy(\.isDrained)
    }

    func wakePump() {
        pumpWaiter?.resume()
        pumpWaiter = nil
    }
}
