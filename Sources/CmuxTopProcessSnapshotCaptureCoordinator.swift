import Foundation

/// Serializes synchronous process snapshot captures and shares compatible in-flight work.
// NSCondition preserves the synchronous socket API; all mutable state is accessed while it is held.
nonisolated final class CmuxTopProcessSnapshotCaptureCoordinator: @unchecked Sendable {
    typealias CaptureProvider = @Sendable (
        _ includeProcessDetails: Bool,
        _ includeCMUXScope: Bool
    ) -> CmuxTopProcessSnapshot
    typealias NowProvider = @Sendable () -> Date

    private struct Requirements: Sendable {
        let includeProcessDetails: Bool
        let includeCMUXScope: Bool

        func satisfies(_ requested: Requirements) -> Bool {
            (includeProcessDetails || !requested.includeProcessDetails)
                && (includeCMUXScope || !requested.includeCMUXScope)
        }
    }

    private final class InFlightCapture {
        enum Completion {
            case pending
            case finished(CmuxTopProcessSnapshot)
        }

        let sequence: UInt64
        let requirements: Requirements
        var completion = Completion.pending

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
        captureProvider: @escaping CaptureProvider = { includeProcessDetails, includeCMUXScope in
            CmuxTopProcessSnapshot.capture(
                includeProcessDetails: includeProcessDetails,
                includeCMUXScope: includeCMUXScope
            )
        },
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
            startedAfter: nil
        )
    }

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
            startedAfter: boundary
        )
    }

    private func capture(
        requirements: Requirements,
        maximumAge: TimeInterval?,
        startedAfter boundary: UInt64?
    ) -> CmuxTopProcessSnapshot {
        condition.lock()
        while true {
            if let maximumAge,
               let cachedSnapshot,
               let cachedRequirements,
               cachedRequirements.satisfies(requirements),
               nowProvider().timeIntervalSince(cachedSnapshot.sampledAt) <= maximumAge {
                condition.unlock()
                return cachedSnapshot
            }

            if let inFlightCapture {
                let startedAfterBoundary = boundary.map { inFlightCapture.sequence > $0 } ?? true
                if startedAfterBoundary,
                   inFlightCapture.requirements.satisfies(requirements) {
                    while case .pending = inFlightCapture.completion {
                        condition.wait()
                    }
                    switch inFlightCapture.completion {
                    case .pending:
                        continue
                    case .finished(let snapshot):
                        condition.unlock()
                        return snapshot
                    }
                }

                while case .pending = inFlightCapture.completion {
                    condition.wait()
                }
                continue
            }

            nextCaptureSequence = nextCaptureSequence &+ 1
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
            capture.completion = .finished(snapshot)
            cachedSnapshot = snapshot
            cachedRequirements = requirements
            if inFlightCapture === capture {
                inFlightCapture = nil
            }
            condition.broadcast()
            condition.unlock()
            return snapshot
        }
    }
}
