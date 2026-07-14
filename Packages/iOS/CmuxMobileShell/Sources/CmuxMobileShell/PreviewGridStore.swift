import CMUXMobileCore
import Foundation

/// Per-surface render-grid fan-out with independently coalesced update streams.
///
/// The store itself is deliberately not observable. Each consumer receives an
/// `AsyncStream` for one surface, so an update cannot invalidate an unrelated
/// card or a list subtree that owns other preview subscriptions.
@MainActor
final class PreviewGridStore {
    private let clock = ContinuousClock()
    private let minimumUpdateInterval: Duration
    private var statesBySurfaceID: [String: PreviewGridSurfaceState] = [:]
    private(set) var isConsumptionActive = true

    /// Creates a store with an injectable per-surface publication cap.
    /// - Parameter maximumUpdatesPerSecond: Maximum snapshot publications per
    ///   second after the first baseline. Production uses four updates/second.
    init(maximumUpdatesPerSecond: Double) {
        let boundedRate = max(0.1, maximumUpdatesPerSecond)
        minimumUpdateInterval = .seconds(1 / boundedRate)
    }

    var registeredSurfaceIDs: Set<String> {
        Set(statesBySurfaceID.keys)
    }

    func updates(
        surfaceID: String,
        onRegistrationEnded: @escaping @MainActor @Sendable () -> Void
    ) -> AsyncStream<PreviewGridSnapshot> {
        let token = UUID()
        let state = statesBySurfaceID[surfaceID] ?? PreviewGridSurfaceState()
        statesBySurfaceID[surfaceID] = state
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            state.continuations[token] = continuation
            continuation.yield(
                state.accumulator.snapshot ?? .awaitingBaseline(surfaceID: surfaceID)
            )
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          let state = self.statesBySurfaceID[surfaceID] else { return }
                    state.continuations.removeValue(forKey: token)
                    guard state.continuations.isEmpty else { return }
                    state.pendingPublicationTask?.cancel()
                    self.statesBySurfaceID.removeValue(forKey: surfaceID)
                    onRegistrationEnded()
                }
            }
        }
    }

    /// Applies a live frame only when that surface has a visible consumer.
    /// - Returns: `true` when the surface needs an authoritative full frame.
    @discardableResult
    func receive(_ frame: MobileTerminalRenderGridFrame) -> Bool {
        guard isConsumptionActive,
              let state = statesBySurfaceID[frame.surfaceID] else { return false }
        switch state.accumulator.apply(frame) {
        case .ignored:
            return false
        case .needsBaseline:
            return true
        case .applied(let snapshot):
            enqueue(snapshot, surfaceID: frame.surfaceID, state: state)
            return false
        }
    }

    func setConsumptionActive(_ isActive: Bool) {
        guard isConsumptionActive != isActive else { return }
        isConsumptionActive = isActive
        resetRegisteredSurfaces()
    }

    func resetForReconnect() {
        resetRegisteredSurfaces()
    }

    func publicationCount(surfaceID: String) -> Int {
        statesBySurfaceID[surfaceID]?.publicationCount ?? 0
    }

    private func resetRegisteredSurfaces() {
        for (surfaceID, state) in statesBySurfaceID {
            state.pendingPublicationTask?.cancel()
            state.pendingPublicationTask = nil
            state.pendingSnapshot = nil
            state.lastPublishedAt = nil
            state.accumulator.reset()
            for continuation in state.continuations.values {
                continuation.yield(.awaitingBaseline(surfaceID: surfaceID))
            }
        }
    }

    private func enqueue(
        _ snapshot: PreviewGridSnapshot,
        surfaceID: String,
        state: PreviewGridSurfaceState
    ) {
        let now = clock.now
        guard let lastPublishedAt = state.lastPublishedAt else {
            publish(snapshot, at: now, state: state)
            return
        }
        let deadline = lastPublishedAt.advanced(by: minimumUpdateInterval)
        guard now < deadline else {
            state.pendingPublicationTask?.cancel()
            state.pendingPublicationTask = nil
            publish(snapshot, at: now, state: state)
            return
        }
        state.pendingSnapshot = snapshot
        guard state.pendingPublicationTask == nil else { return }
        state.pendingPublicationTask = Task { @MainActor [weak self, weak state] in
            guard let self else { return }
            do {
                // Intentional bounded preview cadence delay; cancellation follows registration/lifecycle.
                try await self.clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.isConsumptionActive,
                  let state,
                  self.statesBySurfaceID[surfaceID] === state,
                  let pending = state.pendingSnapshot else { return }
            state.pendingPublicationTask = nil
            state.pendingSnapshot = nil
            self.publish(pending, at: self.clock.now, state: state)
        }
    }

    private func publish(
        _ snapshot: PreviewGridSnapshot,
        at instant: ContinuousClock.Instant,
        state: PreviewGridSurfaceState
    ) {
        state.lastPublishedAt = instant
        state.pendingSnapshot = nil
        state.publicationCount += 1
        for continuation in state.continuations.values {
            continuation.yield(snapshot)
        }
    }
}
