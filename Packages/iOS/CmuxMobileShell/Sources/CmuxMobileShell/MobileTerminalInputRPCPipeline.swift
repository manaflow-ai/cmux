import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// Bounded settlement tracking for pipelined `terminal.input` RPCs.
///
/// Every dimension is scoped per surface — entry queues, reapers, the
/// lane-transition barrier, and ambiguous-failure poisoning — because input
/// ordering is a property of one PTY, and the host applies each surface's
/// ordered requests independently. Only the four-slot capacity window is
/// shared, bounding the connection-wide outstanding pipelined work.
@MainActor
final class MobileTerminalInputRPCPipeline {
    typealias SettlementHandler = @MainActor (
        Result<Data, any Error>
    ) -> Void

    private struct Entry {
        let id: UUID
        let request: MobileCoreRPCPipelinedRequest
        let settlementHandler: SettlementHandler
    }

    private static let maximumUnsettledRequestCount = 4

    private var entriesBySurfaceID: [String: [Entry]] = [:]
    private var reaperTasksBySurfaceID: [String: Task<Void, Never>] = [:]
    private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
    /// Lane-transition barriers are per surface: ordering only matters within
    /// one PTY, and an app-wide wait would let one terminal's slow response
    /// stall a different terminal's healthy lane.
    private var settledWaitersBySurfaceID: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Surfaces where a pipelined request failed WITHOUT a host-produced
    /// response (timeout, transport loss). The host's ordered worker may still
    /// apply that input late, so handing the surface to the independent lane
    /// could deliver later bytes first. The surface stays on the ordered RPC
    /// path (which remains correctly ordered with a late apply) until the next
    /// connection-lifecycle clear().
    private var surfacesWithAmbiguousFailures: Set<String> = []
    /// The host definitively rejected a pipelined request's bearer. Auth is a
    /// connection-wide property (every surface's requests carry the same
    /// token), so the whole connection parks on the awaited RPC path — whose
    /// force-refresh retry owns the re-auth decision — until the next
    /// connection-lifecycle clear().
    private var authorizationFallbackActive = false
    private var generation = UUID()

    private var totalUnsettledCount: Int {
        entriesBySurfaceID.values.reduce(0) { $0 + $1.count }
    }

    func hasUnsettledRequests(surfaceID: String) -> Bool {
        entriesBySurfaceID[surfaceID]?.isEmpty == false
    }

    func hasAmbiguousFailure(surfaceID: String) -> Bool {
        surfacesWithAmbiguousFailures.contains(surfaceID)
    }

    var hasAuthorizationFallback: Bool {
        authorizationFallbackActive
    }

    /// Records a definitive bearer rejection on a pipelined request. See
    /// ``authorizationFallbackActive``.
    func recordAuthorizationFallback() {
        authorizationFallbackActive = true
    }

    func enqueue(
        surfaceID: String,
        makeRequest: @MainActor () async throws -> MobileCoreRPCPipelinedRequest,
        settlementHandler: @escaping SettlementHandler
    ) async throws {
        let enqueueGeneration = generation
        while totalUnsettledCount >= Self.maximumUnsettledRequestCount {
            await withCheckedContinuation { continuation in
                capacityWaiters.append(continuation)
            }
            guard generation == enqueueGeneration else {
                throw CancellationError()
            }
        }
        let request = try await makeRequest()
        guard generation == enqueueGeneration else {
            // clear() ran while makeRequest() was suspended, so this handle
            // was never added to entries and clear() could not abandon it.
            // Release its session settlement slot before dropping it.
            await request.abandon()
            throw CancellationError()
        }
        entriesBySurfaceID[surfaceID, default: []].append(Entry(
            id: UUID(),
            request: request,
            settlementHandler: settlementHandler
        ))
        startReaperIfNeeded(surfaceID: surfaceID)
    }

    func waitUntilAllSettled(surfaceID: String) async {
        guard hasUnsettledRequests(surfaceID: surfaceID) else { return }
        await withCheckedContinuation { continuation in
            settledWaitersBySurfaceID[surfaceID, default: []].append(continuation)
        }
    }

    /// Whether the host provably processed (and rejected) the request, so its
    /// input can never be applied later. Mirrors the definite-host-response
    /// classification in MobileCoreRPCSession's settlement resolution.
    private static func isDefinitiveHostResponseFailure(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else {
            return false
        }
        switch connectionError {
        case .rpcError, .authorizationFailed, .accountMismatch:
            return true
        default:
            return false
        }
    }

    func clear() {
        generation = UUID()
        let abandonedEntries = entriesBySurfaceID.values.flatMap { $0 }
        entriesBySurfaceID.removeAll()
        surfacesWithAmbiguousFailures.removeAll()
        authorizationFallbackActive = false
        for (_, reaperTask) in reaperTasksBySurfaceID {
            reaperTask.cancel()
        }
        reaperTasksBySurfaceID.removeAll()
        // Dropped entries are never awaited again; release their session
        // settlement slots instead of leaving them to sit until the request
        // deadline (or, once settled, until session teardown). The reapers'
        // cancellation already abandons each surface's head entry; a second
        // abandon is a no-op.
        for entry in abandonedEntries {
            let request = entry.request
            Task { await request.abandon() }
        }
        resumeCapacityWaiters()
        resumeAllSettledWaiters()
    }

    private func startReaperIfNeeded(surfaceID: String) {
        guard reaperTasksBySurfaceID[surfaceID] == nil else { return }
        let reaperGeneration = generation
        reaperTasksBySurfaceID[surfaceID] = Task { @MainActor [weak self] in
            await self?.reapResponses(
                surfaceID: surfaceID,
                generation: reaperGeneration
            )
        }
    }

    private func reapResponses(
        surfaceID: String,
        generation reaperGeneration: UUID
    ) async {
        while generation == reaperGeneration,
              let entry = entriesBySurfaceID[surfaceID]?.first {
            let result: Result<Data, any Error>
            do {
                result = .success(try await entry.request.response())
            } catch {
                result = .failure(error)
            }
            guard generation == reaperGeneration,
                  entriesBySurfaceID[surfaceID]?.first?.id == entry.id else {
                return
            }
            entriesBySurfaceID[surfaceID]?.removeFirst()
            if case let .failure(error) = result,
               !Self.isDefinitiveHostResponseFailure(error) {
                surfacesWithAmbiguousFailures.insert(surfaceID)
            }
            entry.settlementHandler(result)
            if !hasUnsettledRequests(surfaceID: surfaceID) {
                resumeSettledWaiters(surfaceID: surfaceID)
            }
            // One settlement frees exactly one slot; waking only the
            // longest-parked producer keeps enqueue arrival order even if a
            // second producer ever appears. clear() still wakes everyone.
            resumeNextCapacityWaiter()
        }
        guard generation == reaperGeneration else { return }
        reaperTasksBySurfaceID[surfaceID] = nil
        if hasUnsettledRequests(surfaceID: surfaceID) {
            startReaperIfNeeded(surfaceID: surfaceID)
        } else {
            entriesBySurfaceID[surfaceID] = nil
            resumeSettledWaiters(surfaceID: surfaceID)
        }
    }

    private func resumeNextCapacityWaiter() {
        guard !capacityWaiters.isEmpty else { return }
        capacityWaiters.removeFirst().resume()
    }

    private func resumeCapacityWaiters() {
        let waiters = capacityWaiters
        capacityWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeSettledWaiters(surfaceID: String) {
        guard let waiters = settledWaitersBySurfaceID.removeValue(forKey: surfaceID) else {
            return
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeAllSettledWaiters() {
        let waitersBySurfaceID = settledWaitersBySurfaceID
        settledWaitersBySurfaceID = [:]
        for waiters in waitersBySurfaceID.values {
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}
