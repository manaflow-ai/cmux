import Foundation

/// Serializes synchronous process-table captures and shares compatible in-flight work.
///
/// The socket/task-manager compatibility paths are synchronous, so this small
/// condition bridge protects only coordinator state. Enumeration itself runs
/// after the bridge is released. It retains at most one snapshot and one
/// in-flight generation; callers opt into a documented maximum age or a fresh
/// generation boundary.
nonisolated final class CmuxTopProcessSnapshotCaptureCoordinator: @unchecked Sendable {
    typealias CaptureProvider = @Sendable (Bool, Bool) -> CmuxTopProcessSnapshot
    typealias NowProvider = @Sendable () -> Date

    private struct Requirements: Sendable {
        let includeProcessDetails: Bool
        let includeCMUXScope: Bool

        func satisfies(_ requested: Requirements) -> Bool {
            (includeProcessDetails || !requested.includeProcessDetails) &&
                (includeCMUXScope || !requested.includeCMUXScope)
        }
    }

    private final class InFlightCapture {
        let sequence: UInt64
        let requirements: Requirements
        var snapshot: CmuxTopProcessSnapshot?

        init(sequence: UInt64, requirements: Requirements) {
            self.sequence = sequence
            self.requirements = requirements
        }
    }

    private let condition = NSCondition()
    private let captureProvider: CaptureProvider
    private let nowProvider: NowProvider
    private var cachedSnapshot: CmuxTopProcessSnapshot?
    private var cachedRequirements: Requirements?
    private var nextCaptureSequence: UInt64 = 0
    private var inFlightCapture: InFlightCapture?

    init(
        captureProvider: @escaping CaptureProvider,
        nowProvider: @escaping NowProvider = { Date() }
    ) {
        self.captureProvider = captureProvider
        self.nowProvider = nowProvider
    }

    func captureCached(
        includeProcessDetails: Bool,
        includeCMUXScope: Bool,
        maximumAge: TimeInterval
    ) -> CmuxTopProcessSnapshot {
        capture(
            requirements: Requirements(
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope
            ),
            maximumAge: maximumAge,
            minimumSequence: nil
        )
    }

    /// Captures after the generation observed at request time. If a compatible
    /// capture is already in flight, callers join it instead of starting a
    /// second census; a completed older generation is never reused.
    func captureCoordinatedFresh(
        includeProcessDetails: Bool,
        includeCMUXScope: Bool
    ) -> CmuxTopProcessSnapshot {
        condition.lock()
        let boundary = nextCaptureSequence
        condition.unlock()
        return capture(
            requirements: Requirements(
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope
            ),
            maximumAge: nil,
            minimumSequence: boundary
        )
    }

    private func capture(
        requirements: Requirements,
        maximumAge: TimeInterval?,
        minimumSequence: UInt64?
    ) -> CmuxTopProcessSnapshot {
        condition.lock()
        while true {
            if let maximumAge,
               let cachedSnapshot,
               let cachedRequirements,
               cachedRequirements.satisfies(requirements),
               nowProvider().timeIntervalSince(cachedSnapshot.sampledAt) <= max(0, maximumAge) {
                condition.unlock()
                return cachedSnapshot
            }

            if let inFlightCapture {
                let isNewEnough = minimumSequence.map {
                    // A request that arrived while this generation was running
                    // joins it. A request with no active generation gets a
                    // strict `>` boundary below and therefore starts fresh.
                    inFlightCapture.sequence >= $0
                } ?? true
                if isNewEnough && inFlightCapture.requirements.satisfies(requirements) {
                    while inFlightCapture.snapshot == nil {
                        condition.wait()
                    }
                    let snapshot = inFlightCapture.snapshot!
                    condition.unlock()
                    return snapshot
                }
                while inFlightCapture.snapshot == nil {
                    condition.wait()
                }
                continue
            }

            nextCaptureSequence &+= 1
            let capture = InFlightCapture(
                sequence: nextCaptureSequence,
                requirements: requirements
            )
            inFlightCapture = capture
            condition.unlock()
            let snapshot = captureProvider(
                requirements.includeProcessDetails,
                requirements.includeCMUXScope
            )
            condition.lock()
            capture.snapshot = snapshot
            cachedSnapshot = snapshot
            cachedRequirements = requirements
            if inFlightCapture === capture { inFlightCapture = nil }
            condition.broadcast()
            condition.unlock()
            return snapshot
        }
    }
}
