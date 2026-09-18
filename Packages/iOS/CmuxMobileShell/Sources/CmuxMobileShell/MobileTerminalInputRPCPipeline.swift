import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// Settlement tracking for pipelined `terminal.input` RPCs.
///
/// Every dimension is scoped per surface — entry queues, reapers, the
/// lane-transition barrier, and ambiguous-failure poisoning — because input
/// ordering is a property of one PTY, and the host applies each surface's
/// ordered requests independently. Admission is handled by the host's shared
/// RPC work quota; this client object only tracks settlement and ordering.
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

    private var entriesBySurfaceID: [String: [Entry]] = [:]
    private var reaperTasksBySurfaceID: [String: Task<Void, Never>] = [:]
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
    private var generation = UUID()

    func hasUnsettledRequests(surfaceID: String) -> Bool {
        entriesBySurfaceID[surfaceID]?.isEmpty == false
    }

    func hasAmbiguousFailure(surfaceID: String) -> Bool {
        surfacesWithAmbiguousFailures.contains(surfaceID)
    }

    func enqueue(
        surfaceID: String,
        makeRequest: @MainActor () async throws -> MobileCoreRPCPipelinedRequest,
        settlementHandler: @escaping SettlementHandler
    ) async throws {
        let enqueueGeneration = generation
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
