import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation

/// The result of dialing one discovered Mac before any foreground ownership.
enum ZeroTouchDialAttempt {
    /// The Mac answered on this client; the receiver owns the client.
    case reachable(MobileCoreRPCClient)
    /// The dial or its first response failed.
    case failed(any Error)
    /// Local policy leaves nothing this build may dial for the Mac, or the
    /// race closed before the dial started.
    case skipped
}

/// Dials discovered Macs concurrently and yields each one as soon as it
/// answers, so a stalled directory entry never delays a live Mac behind it.
///
/// Every candidate dials at once up to ``maximumConcurrentDials``, which
/// stays inside the shell's connect-attempt budget so dials past it queue
/// instead of being refused. Each finished dial starts the next queued one.
/// A dial that outlives its own deadline is torn down and frees its slot, so
/// a window of Macs that accept the transport but never answer cannot hold
/// the queue until the whole reconnect attempt expires.
///
/// The consumer claims each yielded client and hands it to the foreground
/// connect. ``close()`` tears down dials still in flight, drops queued ones,
/// and disconnects every reachable client that was never claimed, including
/// ones that answer late. A newer reconnect generation, and sign-out, close
/// the race so its dials cannot hold endpoint leases the new pass needs.
@MainActor
final class ZeroTouchDialRace {
    typealias Dial = @Sendable @MainActor (
        MobilePairedMac,
        _ track: @MainActor (MobileCoreRPCClient) -> Bool
    ) async -> ZeroTouchDialAttempt
    /// Returns when one dial's deadline passes; throws when cancelled.
    typealias DialDeadline = @Sendable () async throws -> Void

    struct Arrival: Sendable {
        let mac: MobilePairedMac
        let client: MobileCoreRPCClient
    }

    /// Half the shell's connect-attempt budget. A stalled dial torn down by
    /// ``close()`` can linger as cleanup debt against that same budget, so the
    /// other half stays free for the adopted foreground lane, secondary Macs,
    /// and the next pass.
    static let maximumConcurrentDials =
        MobileRPCConnectAttemptRegistry.maximumGlobalOutstandingAttempts / 2

    let arrivals: AsyncStream<Arrival>
    /// The most recent dial failure, for reporting when no Mac answered.
    private(set) var lastFailure: (any Error)?
    private let continuation: AsyncStream<Arrival>.Continuation
    private let dial: Dial
    private let maximumConcurrentDials: Int
    private let dialDeadline: DialDeadline?
    private var queued: ArraySlice<MobilePairedMac>
    private var dials: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var expiredDials: Set<UUID> = []
    private var inFlightClients: [UUID: MobileCoreRPCClient] = [:]
    private var unclaimedClients: [ObjectIdentifier: MobileCoreRPCClient] = [:]
    private var isClosed = false

    init(
        candidates: [MobilePairedMac],
        maximumConcurrentDials: Int = ZeroTouchDialRace.maximumConcurrentDials,
        dialDeadline: DialDeadline? = nil,
        dial: @escaping Dial
    ) {
        let (arrivals, continuation) = AsyncStream.makeStream(of: Arrival.self)
        self.arrivals = arrivals
        self.continuation = continuation
        self.dial = dial
        self.maximumConcurrentDials = max(1, maximumConcurrentDials)
        self.dialDeadline = dialDeadline
        queued = candidates[...]
        startQueuedDials()
    }

    /// Takes ownership of a yielded client so ``close()`` leaves it alone.
    /// Returns `nil` for an arrival still buffered when the race closed; the
    /// race already released that client.
    func claim(_ arrival: Arrival) -> MobileCoreRPCClient? {
        guard !isClosed,
              unclaimedClients.removeValue(forKey: ObjectIdentifier(arrival.client)) != nil
        else { return nil }
        startQueuedDials()
        return arrival.client
    }

    /// Tears down in-flight dials, drops queued ones, and releases every
    /// unclaimed client.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        queued = []
        for dial in dials.values {
            dial.cancel()
        }
        for deadline in deadlines.values {
            deadline.cancel()
        }
        deadlines.removeAll()
        for client in inFlightClients.values {
            Self.release(client)
        }
        inFlightClients.removeAll()
        for client in unclaimedClients.values {
            Self.release(client)
        }
        unclaimedClients.removeAll()
        continuation.finish()
    }

    private func startQueuedDials() {
        // An answered Mac keeps its slot until claimed or released: its live
        // transport still holds a connect-budget lease.
        while !isClosed,
              dials.count + unclaimedClients.count < maximumConcurrentDials,
              let mac = queued.popFirst() {
            let token = UUID()
            dials[token] = Task { @MainActor [weak self, dial] in
                let attempt = await dial(mac) { [weak self] client in
                    self?.track(client, token: token) ?? false
                }
                guard let self else {
                    if case let .reachable(client) = attempt {
                        await client.disconnect()
                    }
                    return
                }
                self.finishDial(of: mac, token: token, attempt: attempt)
            }
            if let dialDeadline {
                deadlines[token] = Task { @MainActor [weak self] in
                    do {
                        try await dialDeadline()
                    } catch {
                        return
                    }
                    self?.expireDial(token)
                }
            }
        }
        if dials.isEmpty, queued.isEmpty {
            continuation.finish()
        }
    }

    /// Records a dial's client so ``close()`` can tear it down mid-dial.
    /// Returns `false` once the race has closed; the dial must not proceed.
    private func track(_ client: MobileCoreRPCClient, token: UUID) -> Bool {
        guard !isClosed, !expiredDials.contains(token) else { return false }
        inFlightClients[token] = client
        return true
    }

    private func finishDial(
        of mac: MobilePairedMac,
        token: UUID,
        attempt: ZeroTouchDialAttempt
    ) {
        deadlines.removeValue(forKey: token)?.cancel()
        if expiredDials.remove(token) != nil {
            // The deadline already freed this slot and reported the timeout.
            if case let .reachable(client) = attempt {
                Self.release(client)
            }
            return
        }
        dials[token] = nil
        inFlightClients[token] = nil
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
        startQueuedDials()
    }

    /// Tears down a dial that outlived its deadline and starts the next
    /// queued Mac in its slot.
    private func expireDial(_ token: UUID) {
        deadlines[token] = nil
        guard !isClosed, let dial = dials.removeValue(forKey: token) else { return }
        expiredDials.insert(token)
        dial.cancel()
        if let client = inFlightClients.removeValue(forKey: token) {
            Self.release(client)
        }
        lastFailure = MobileShellConnectionError.requestTimedOut
        startQueuedDials()
    }

    private static func release(_ client: MobileCoreRPCClient) {
        client.retire()
        Task { await client.disconnect() }
    }
}
