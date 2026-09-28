import CmuxMobilePairedMac
import CmuxMobileRPC

/// The result of dialing one discovered Mac before any foreground ownership.
enum ZeroTouchDialAttempt {
    /// The Mac answered on this client; the receiver owns the client.
    case reachable(MobileCoreRPCClient)
    /// The dial or its first response failed.
    case failed(any Error)
    /// Local policy leaves nothing this build may dial for the Mac.
    case skipped
}

/// Dials every discovered Mac at once and yields each one as soon as it
/// answers, so a stalled directory entry never delays a live Mac behind it.
///
/// The consumer claims each yielded client and hands it to the foreground
/// connect. ``close()`` cancels dials still in flight and disconnects every
/// reachable client that was never claimed, including ones that answer late.
@MainActor
final class ZeroTouchDialRace {
    struct Arrival: Sendable {
        let mac: MobilePairedMac
        let client: MobileCoreRPCClient
    }

    let arrivals: AsyncStream<Arrival>
    /// The most recent dial failure, for reporting when no Mac answered.
    private(set) var lastFailure: (any Error)?
    private let continuation: AsyncStream<Arrival>.Continuation
    private var dials: [Task<Void, Never>] = []
    private var unclaimedClients: [ObjectIdentifier: MobileCoreRPCClient] = [:]
    private var pendingDialCount: Int
    private var isClosed = false

    init(
        candidates: [MobilePairedMac],
        dial: @escaping @Sendable @MainActor (MobilePairedMac) async -> ZeroTouchDialAttempt
    ) {
        let (arrivals, continuation) = AsyncStream.makeStream(of: Arrival.self)
        self.arrivals = arrivals
        self.continuation = continuation
        pendingDialCount = candidates.count
        guard !candidates.isEmpty else {
            continuation.finish()
            return
        }
        dials = candidates.map { mac in
            Task { @MainActor [weak self] in
                let attempt = await dial(mac)
                guard let self else {
                    if case let .reachable(client) = attempt {
                        await client.disconnect()
                    }
                    return
                }
                self.finishDial(of: mac, attempt: attempt)
            }
        }
    }

    /// Takes ownership of a yielded client so ``close()`` leaves it alone.
    func claim(_ arrival: Arrival) -> MobileCoreRPCClient {
        unclaimedClients[ObjectIdentifier(arrival.client)] = nil
        return arrival.client
    }

    /// Cancels in-flight dials and releases every unclaimed client.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        for dial in dials {
            dial.cancel()
        }
        for client in unclaimedClients.values {
            Self.release(client)
        }
        unclaimedClients.removeAll()
        continuation.finish()
    }

    private func finishDial(of mac: MobilePairedMac, attempt: ZeroTouchDialAttempt) {
        pendingDialCount -= 1
        switch attempt {
        case let .reachable(client):
            if isClosed {
                Self.release(client)
            } else {
                unclaimedClients[ObjectIdentifier(client)] = client
                continuation.yield(Arrival(mac: mac, client: client))
            }
        case let .failed(error):
            lastFailure = error
        case .skipped:
            break
        }
        if pendingDialCount == 0 {
            continuation.finish()
        }
    }

    private static func release(_ client: MobileCoreRPCClient) {
        client.retire()
        Task { await client.disconnect() }
    }
}
