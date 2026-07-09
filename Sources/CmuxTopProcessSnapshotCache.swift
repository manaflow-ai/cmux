import Foundation
import os

nonisolated struct CmuxTopProcessSnapshotRequirements: OptionSet, Sendable {
    let rawValue: UInt8

    static let processDetails = Self(rawValue: 1 << 0)
    static let cmuxScope = Self(rawValue: 1 << 1)
    static let basic: Self = []
}

actor CmuxTopProcessSnapshotStore {
    typealias Now = @Sendable () async -> Date
    typealias Capture = @Sendable (CmuxTopProcessSnapshotRequirements) async -> CmuxTopProcessSnapshot

    static let shared = CmuxTopProcessSnapshotStore()

    private struct CachedSnapshot {
        let snapshot: CmuxTopProcessSnapshot
        let requirements: CmuxTopProcessSnapshotRequirements
        let storedAt: Date
    }

    private struct InFlightCapture {
        let id: UInt64
        let requirements: CmuxTopProcessSnapshotRequirements
        let task: Task<CmuxTopProcessSnapshot, Never>
    }

    private let now: Now
    private let capture: Capture
    private var cached: CachedSnapshot?
    private var inFlight: InFlightCapture?
    private var nextCaptureID: UInt64 = 0

    init(
        now: @escaping Now = { Date() },
        capture: @escaping Capture = { requirements in
            CmuxTopProcessSnapshot.capture(
                includeProcessDetails: requirements.contains(.processDetails),
                includeCMUXScope: requirements.contains(.cmuxScope)
            )
        }
    ) {
        self.now = now
        self.capture = capture
    }

    func snapshot(
        requirements: CmuxTopProcessSnapshotRequirements,
        maximumAge: TimeInterval
    ) async -> CmuxTopProcessSnapshot {
        let requestedAt = await now()
        if let cached = validCachedSnapshot(
            requirements: requirements,
            maximumAge: maximumAge,
            now: requestedAt
        ) {
            return cached
        }

        while true {
            if let inFlight {
                let snapshot = await inFlight.task.value
                await finishCapture(inFlight, snapshot: snapshot)
                if inFlight.requirements.isSuperset(of: requirements) {
                    return snapshot
                }
                let now = await now()
                if let cached = validCachedSnapshot(
                    requirements: requirements,
                    maximumAge: maximumAge,
                    now: now
                ) {
                    return cached
                }
                continue
            }

            nextCaptureID &+= 1
            let id = nextCaptureID
            let capture = self.capture
            let task = Task.detached(priority: .utility) {
                await capture(requirements)
            }
            let started = InFlightCapture(id: id, requirements: requirements, task: task)
            inFlight = started
            let snapshot = await task.value
            await finishCapture(started, snapshot: snapshot)
            return snapshot
        }
    }

    private func finishCapture(
        _ completed: InFlightCapture,
        snapshot: CmuxTopProcessSnapshot
    ) async {
        guard inFlight?.id == completed.id else { return }
        cached = CachedSnapshot(
            snapshot: snapshot,
            requirements: completed.requirements,
            storedAt: await now()
        )
        inFlight = nil
    }

    private func validCachedSnapshot(
        requirements: CmuxTopProcessSnapshotRequirements,
        maximumAge: TimeInterval,
        now: Date
    ) -> CmuxTopProcessSnapshot? {
        guard let cached,
              cached.requirements.isSuperset(of: requirements),
              now.timeIntervalSince(cached.storedAt) <= max(0, maximumAge) else {
            return nil
        }
        return cached.snapshot
    }
}

private nonisolated struct CmuxTopProcessSnapshotCacheState {
    var snapshot: CmuxTopProcessSnapshot?
    var includeProcessDetails = false
    var includeCMUXScope = true
}

// Synchronous compatibility for one-shot call sites. Periodic consumers use
// CmuxTopProcessSnapshotStore so capture is deduplicated without blocking them.
private nonisolated let cmuxTopProcessSnapshotCache = OSAllocatedUnfairLock(
    initialState: CmuxTopProcessSnapshotCacheState()
)

nonisolated extension CmuxTopProcessSnapshot {
    static func captureCached(
        includeProcessDetails: Bool = false,
        includeCMUXScope: Bool = true,
        maximumAge: TimeInterval
    ) -> CmuxTopProcessSnapshot {
        let now = Date()
        if let cached = cmuxTopProcessSnapshotCache.withLock({ state -> CmuxTopProcessSnapshot? in
            guard let snapshot = state.snapshot,
                  Self.cachedSnapshotDetailsSatisfy(
                      state.includeProcessDetails,
                      requested: includeProcessDetails
                  ),
                  Self.cachedSnapshotCMUXScopeSatisfies(
                      state.includeCMUXScope,
                      requested: includeCMUXScope
                  ),
                  now.timeIntervalSince(snapshot.sampledAt) <= maximumAge else {
                return nil
            }
            return snapshot
        }) {
            return cached
        }

        let snapshot = capture(
            includeProcessDetails: includeProcessDetails,
            includeCMUXScope: includeCMUXScope
        )
        return cmuxTopProcessSnapshotCache.withLock { state in
            let storeTime = Date()
            if let cached = state.snapshot,
               Self.cachedSnapshotDetailsSatisfy(
                   state.includeProcessDetails,
                   requested: includeProcessDetails
               ),
               Self.cachedSnapshotCMUXScopeSatisfies(
                   state.includeCMUXScope,
                   requested: includeCMUXScope
               ),
               storeTime.timeIntervalSince(cached.sampledAt) <= maximumAge {
                return cached
            }
            state.snapshot = snapshot
            state.includeProcessDetails = includeProcessDetails
            state.includeCMUXScope = includeCMUXScope
            return snapshot
        }
    }

    private static func cachedSnapshotDetailsSatisfy(
        _ cachedIncludesProcessDetails: Bool,
        requested: Bool
    ) -> Bool {
        cachedIncludesProcessDetails || !requested
    }

    private static func cachedSnapshotCMUXScopeSatisfies(
        _ cachedIncludesCMUXScope: Bool,
        requested: Bool
    ) -> Bool {
        cachedIncludesCMUXScope || !requested
    }
}
