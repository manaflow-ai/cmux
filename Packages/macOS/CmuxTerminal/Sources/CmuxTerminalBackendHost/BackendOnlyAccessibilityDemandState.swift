internal import CmuxTerminalBackend
internal import Foundation

/// Deterministic presentation-scoped lease planner for semantic retention.
///
/// Main-actor runtime code owns this value and serializes the returned
/// operations. Failed acquire operations remain pending so an ambiguous retry
/// reuses the exact request identity and generation expectation.
struct BackendOnlyAccessibilityDemandState: Sendable {
    enum Operation: Equatable, Sendable {
        case acquire(
            requestID: UUID,
            presentationID: PresentationID,
            expectedGeneration: UInt64,
            expectedDemandGeneration: UInt64?
        )
        case release(
            presentationID: PresentationID,
            expectedGeneration: UInt64,
            demandGeneration: UInt64
        )
    }

    private struct Presentation: Equatable, Sendable {
        let id: PresentationID
        let generation: UInt64
    }

    private struct Admission: Equatable, Sendable {
        let requestID: UUID
        let presentation: Presentation
        let demandGeneration: UInt64

        var releaseOperation: Operation {
            .release(
                presentationID: presentation.id,
                expectedGeneration: presentation.generation,
                demandGeneration: demandGeneration
            )
        }
    }

    private(set) var explicitObserverCount = 0
    private var streamObservers: Set<UUID> = []
    private var presentation: Presentation?
    private var admission: Admission?
    private var pendingAcquire: Operation?
    private var pendingReleases: [Operation] = []
    private var operationInFlight: Operation?

    var observerCount: Int {
        explicitObserverCount + streamObservers.count
    }

    var admittedDemandGeneration: UInt64? {
        guard isDemandAdmitted else { return nil }
        return admission?.demandGeneration
    }

    var isDemandAdmitted: Bool {
        guard observerCount > 0,
              let presentation,
              let admission else { return false }
        let release = admission.releaseOperation
        return admission.presentation == presentation
            && operationInFlight != release
            && !pendingReleases.contains(release)
    }

    mutating func attach(presentationID: PresentationID, generation: UInt64) {
        precondition(generation > 0)
        presentation = Presentation(id: presentationID, generation: generation)
    }

    mutating func detach(presentationID: PresentationID, generation: UInt64) {
        guard presentation == Presentation(id: presentationID, generation: generation) else {
            return
        }
        presentation = nil
    }

    mutating func addExplicitObserver() {
        explicitObserverCount += 1
    }

    mutating func removeExplicitObserver() {
        guard explicitObserverCount > 0 else { return }
        explicitObserverCount -= 1
    }

    mutating func addStreamObserver(_ identifier: UUID) {
        streamObservers.insert(identifier)
    }

    mutating func removeStreamObserver(_ identifier: UUID) {
        streamObservers.remove(identifier)
    }

    mutating func removeAllObservers() {
        explicitObserverCount = 0
        streamObservers.removeAll(keepingCapacity: false)
    }

    mutating func beginNextOperation(requestID: UUID) -> Operation? {
        guard operationInFlight == nil else { return nil }
        if let pendingAcquire {
            operationInFlight = pendingAcquire
            return pendingAcquire
        }
        if let release = pendingReleases.first {
            operationInFlight = release
            return release
        }
        if let admission {
            guard observerCount == 0 || admission.presentation != presentation else {
                return nil
            }
            let release = admission.releaseOperation
            enqueueRelease(release)
            operationInFlight = release
            return release
        }
        guard observerCount > 0, let presentation else { return nil }
        let acquire = Operation.acquire(
            requestID: requestID,
            presentationID: presentation.id,
            expectedGeneration: presentation.generation,
            expectedDemandGeneration: nil
        )
        pendingAcquire = acquire
        operationInFlight = acquire
        return acquire
    }

    mutating func completeAcquire(
        _ operation: Operation,
        demandGeneration: UInt64
    ) {
        guard case let .acquire(
            requestID,
            presentationID,
            expectedGeneration,
            expectedDemandGeneration
        ) = operation,
        demandGeneration > 0,
        expectedDemandGeneration.map({ demandGeneration > $0 }) ?? true else { return }
        if operationInFlight == operation {
            operationInFlight = nil
        }
        if pendingAcquire == operation {
            pendingAcquire = nil
        }
        let acquired = Admission(
            requestID: requestID,
            presentation: Presentation(
                id: presentationID,
                generation: expectedGeneration
            ),
            demandGeneration: demandGeneration
        )
        if let current = admission, current != acquired {
            if current.demandGeneration > acquired.demandGeneration {
                enqueueRelease(acquired.releaseOperation)
                return
            }
            enqueueRelease(current.releaseOperation)
        }
        if presentation == acquired.presentation, observerCount > 0 {
            admission = acquired
        } else {
            admission = nil
            enqueueRelease(acquired.releaseOperation)
        }
    }

    mutating func completeRelease(_ operation: Operation, released _: Bool) {
        guard case let .release(
            presentationID,
            expectedGeneration,
            demandGeneration
        ) = operation else { return }
        if operationInFlight == operation {
            operationInFlight = nil
        }
        pendingReleases.removeAll { $0 == operation }
        let releasedPresentation = Presentation(
            id: presentationID,
            generation: expectedGeneration
        )
        if admission?.presentation == releasedPresentation,
           admission?.demandGeneration == demandGeneration {
            // A false result means this generation is already absent or was
            // replaced remotely. Either way it cannot remain an admitted fence.
            admission = nil
        }
    }

    mutating func fail(_ operation: Operation) {
        guard operationInFlight == operation else { return }
        operationInFlight = nil
        // Acquire remains in pendingAcquire for an identity-stable retry.
        // Release remains represented by admission or pendingReleases.
    }

    private mutating func enqueueRelease(_ operation: Operation) {
        guard !pendingReleases.contains(operation) else { return }
        pendingReleases.append(operation)
    }
}
