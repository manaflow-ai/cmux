import Foundation
internal import os

typealias TerminalSurfaceRuntimeOwnershipRecovery =
    @MainActor @Sendable (TerminalSurfaceRuntimeOwnershipReservation) -> Void
typealias TerminalSurfaceRuntimeOwnershipRecoveryFailure =
    @MainActor @Sendable () -> Void

/// Synchronous, bounded admission for native-surface ownership.
///
/// Creation, public teardown, and deinit cannot suspend while transferring a
/// native pointer, so this ledger uses one short unfair-lock critical section.
/// An actor would make creation and deinit await while they hold sole pointer
/// custody, so the lock is the explicit synchronous isolation boundary.
/// Each ownership reservation also holds one submission-ingress slot until the
/// teardown submission is dequeued or the unused ownership is released.
/// Native work never runs under the lock. A fully stalled close pool degrades
/// admission until a worker returns, preventing repeated create/close cycles
/// from growing an unbounded retained teardown backlog.
final class TerminalSurfaceRuntimeOwnershipAdmission: @unchecked Sendable {
    private let maximumOwnerCount: Int
    private let recoveryRescanScheduler:
        TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler
    private let state = OSAllocatedUnfairLock(
        initialState: TerminalSurfaceRuntimeOwnershipAdmissionState()
    )

    init(
        maximumOwnerCount: Int,
        recoveryRescanScheduler:
            TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler? = nil
    ) {
        precondition(
            maximumOwnerCount >= TerminalSurfaceRuntimeTeardownCoordinator
                .maximumConcurrentCloseTeardownCount,
            "native surface ownership must cover every close worker"
        )
        self.maximumOwnerCount = maximumOwnerCount
        self.recoveryRescanScheduler = recoveryRescanScheduler
            ?? TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler(
                maximumEntryCount: maximumOwnerCount
            )
    }

    func reserve() -> TerminalSurfaceRuntimeOwnershipReservation? {
        state.withLock { state in
            guard !state.closeTeardownDegraded,
                  !state.closeTeardownAllStalled,
                  state.reservationIDs.count < maximumOwnerCount,
                  state.ingressReservationIDs.count < maximumOwnerCount else {
                return nil
            }
            return reserveOwnershipAndIngress(in: &state)
        }
    }

    func reserve(
        recoveryID: UUID,
        onRecovery: @escaping TerminalSurfaceRuntimeOwnershipRecovery,
        onFailure: @escaping TerminalSurfaceRuntimeOwnershipRecoveryFailure = {},
        capacityReservation:
            TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation? = nil
    ) -> TerminalSurfaceRuntimeOwnershipRecoveryAdmissionResult {
        let output: (
            result: TerminalSurfaceRuntimeOwnershipRecoveryAdmissionResult,
            requestRescan: Bool
        ) = state.withLock { state in
            let claimedCapacity: Bool
            if let capacityReservation {
                guard state.recoveryCapacityReservationIDs.remove(
                    capacityReservation.id
                ) != nil else {
                    return (.rejected, false)
                }
                claimedCapacity = true
            } else {
                claimedCapacity = false
            }
            guard !state.closeTeardownAllStalled else {
                return (.closeTeardownStalled, claimedCapacity)
            }
            if !state.closeTeardownDegraded,
                state.reservationIDs.count < maximumOwnerCount,
                state.ingressReservationIDs.count < maximumOwnerCount
            {
                _ = removeRecoveryAction(recoveryID, from: &state)
                return (
                    .reserved(reserveOwnershipAndIngress(in: &state)),
                    takeRecoveryRescanRequest(from: &state) || claimedCapacity
                )
            }
            if state.recoveryEntriesByID[recoveryID] != nil {
                state.recoveryEntriesByID[recoveryID]?.action = onRecovery
                state.recoveryEntriesByID[recoveryID]?.failure = onFailure
                state.recoveryEntriesByID[recoveryID]?.failureReported = false
                return (.deferred, claimedCapacity)
            }
            guard claimedCapacity || recoveryCapacityIsOpen(in: state) else {
                return (.rejected, false)
            }
            enqueueRecoveryAction(
                onRecovery,
                onFailure: onFailure,
                id: recoveryID,
                in: &state
            )
            return (.deferred, false)
        }
        if output.requestRescan {
            recoveryRescanScheduler.requestRescan()
        }
        return output.result
    }

    func claimRecoveryCapacity()
        -> TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation? {
        state.withLock { state in
            guard overflowRecoveryCapacityIsOpen(in: state) else {
                return nil
            }
            let reservation =
                TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation()
            state.recoveryCapacityReservationIDs.insert(reservation.id)
            return reservation
        }
    }

    func recoveryCapacityIsOpen() -> Bool {
        state.withLock { overflowRecoveryCapacityIsOpen(in: $0) }
    }

    func releaseRecoveryCapacity(
        _ reservation:
            TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation
    ) {
        let released = state.withLock { state in
            state.recoveryCapacityReservationIDs.remove(reservation.id) != nil
        }
        if released {
            recoveryRescanScheduler.requestRescan()
        }
    }

    func contains(_ reservation: TerminalSurfaceRuntimeOwnershipReservation) -> Bool {
        state.withLock { $0.reservationIDs.contains(reservation.id) }
    }

    func claimIngressReservation(
        for reservation: TerminalSurfaceRuntimeOwnershipReservation
    ) -> TerminalSurfaceRuntimeTeardownIngressReservation? {
        state.withLock { state in
            guard state.reservationIDs.contains(reservation.id),
                  state.unclaimedOwnershipIngressReservationIDs.remove(
                      reservation.id
                  ) != nil else {
                return nil
            }
            return TerminalSurfaceRuntimeTeardownIngressReservation(
                id: reservation.id
            )
        }
    }

    func reserveControlIngress()
        -> TerminalSurfaceRuntimeTeardownIngressReservation? {
        let result: (
            TerminalSurfaceRuntimeTeardownIngressReservation?,
            TerminalSurfaceRuntimeOwnershipRecoveryGrant?,
            Bool
        ) = state.withLock { state in
            if let recoveryGrant = takeNextRecoveryGrant(from: &state) {
                return (
                    nil,
                    recoveryGrant,
                    takeRecoveryRescanRequest(from: &state)
                )
            }
            guard state.ingressReservationIDs.count < maximumOwnerCount else {
                return (nil, nil, false)
            }
            let reservation = TerminalSurfaceRuntimeTeardownIngressReservation()
            state.ingressReservationIDs.insert(reservation.id)
            return (reservation, nil, false)
        }
        schedule(result.1)
        if result.2 {
            recoveryRescanScheduler.requestRescan()
        }
        return result.0
    }

    func releaseIngress(
        _ reservation: TerminalSurfaceRuntimeTeardownIngressReservation
    ) {
        let output = state.withLock { state in
            _ = state.ingressReservationIDs.remove(reservation.id)
            _ = state.unclaimedOwnershipIngressReservationIDs.remove(
                reservation.id
            )
            let grant = takeNextRecoveryGrant(from: &state)
            return (grant, takeRecoveryRescanRequest(from: &state))
        }
        schedule(output.0)
        if output.1 {
            recoveryRescanScheduler.requestRescan()
        }
    }

    func releaseFailedSubmission(
        ownership reservation: TerminalSurfaceRuntimeOwnershipReservation,
        ingress ingressReservation:
            TerminalSurfaceRuntimeTeardownIngressReservation
    ) {
        let output = state.withLock { state in
            _ = state.reservationIDs.remove(reservation.id)
            _ = state.ingressReservationIDs.remove(ingressReservation.id)
            _ = state.unclaimedOwnershipIngressReservationIDs.remove(
                reservation.id
            )
            let grant = takeNextRecoveryGrant(from: &state)
            return (grant, takeRecoveryRescanRequest(from: &state))
        }
        schedule(output.0)
        if output.1 {
            recoveryRescanScheduler.requestRescan()
        }
    }

    func release(_ reservation: TerminalSurfaceRuntimeOwnershipReservation) {
        let output = state.withLock { state in
            _ = state.reservationIDs.remove(reservation.id)
            if state.unclaimedOwnershipIngressReservationIDs.remove(
                reservation.id
            ) != nil {
                _ = state.ingressReservationIDs.remove(reservation.id)
            }
            let grant = takeNextRecoveryGrant(from: &state)
            return (grant, takeRecoveryRescanRequest(from: &state))
        }
        schedule(output.0)
        if output.1 {
            recoveryRescanScheduler.requestRescan()
        }
    }

    func setCloseTeardownDegraded(_ degraded: Bool) {
        let output = state.withLock { state in
            state.closeTeardownDegraded = degraded
            let grant = takeNextRecoveryGrant(from: &state)
            return (grant, takeRecoveryRescanRequest(from: &state))
        }
        schedule(output.0)
        if output.1 {
            recoveryRescanScheduler.requestRescan()
        }
    }

    func failRecoveriesForAllStalledCloseTeardowns()
        -> [TerminalSurfaceRuntimeOwnershipRecoveryFailure] {
        state.withLock { state in
            state.closeTeardownAllStalled = true
            var failures: [TerminalSurfaceRuntimeOwnershipRecoveryFailure] = []
            var recoveryID = state.recoveryHeadID
            while let currentID = recoveryID,
                  let entry = state.recoveryEntriesByID[currentID] {
                recoveryID = entry.nextID
                guard !entry.failureReported else { continue }
                state.recoveryEntriesByID[currentID]?.failureReported = true
                failures.append(entry.failure)
            }
            state.pendingRecoveryFailureCount += failures.count
            precondition(
                state.pendingRecoveryFailureCount <= maximumOwnerCount,
                "stalled recovery failures must remain bounded"
            )
            state.recoveryRescanRequested = false
            return failures
        }
    }

    func completeStalledCloseRecoveryFailures(_ completedCount: Int) {
        precondition(completedCount > 0)
        let output = state.withLock { state in
            precondition(
                completedCount <= state.pendingRecoveryFailureCount,
                "completed stalled recovery failures must be owned"
            )
            let capacityWasOpen = recoveryCapacityIsOpen(in: state)
            state.pendingRecoveryFailureCount -= completedCount
            let recoveryCapacityOpened =
                !capacityWasOpen && recoveryCapacityIsOpen(in: state)
            let grant = takeNextRecoveryGrant(from: &state)
            return (
                grant,
                takeRecoveryRescanRequest(from: &state)
                    || recoveryCapacityOpened
            )
        }
        schedule(output.0)
        if output.1 {
            recoveryRescanScheduler.requestRescan()
        }
    }

    func clearAllStalledCloseTeardowns() {
        let grant: TerminalSurfaceRuntimeOwnershipRecoveryGrant?
        grant = state.withLock { state in
            guard state.closeTeardownAllStalled else {
                return nil
            }
            state.closeTeardownAllStalled = false
            let grant = takeNextRecoveryGrant(from: &state)
            _ = takeRecoveryRescanRequest(from: &state)
            return grant
        }
        schedule(grant)
        recoveryRescanScheduler.requestRescan()
    }

    func cancelRecovery(_ recoveryID: UUID) {
        let requestRescan = state.withLock { state in
            _ = removeRecoveryAction(recoveryID, from: &state)
            return takeRecoveryRescanRequest(from: &state)
        }
        if requestRescan {
            recoveryRescanScheduler.requestRescan()
        }
    }

    private func removeRecoveryAction(
        _ recoveryID: UUID,
        from state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> TerminalSurfaceRuntimeOwnershipRecovery? {
        guard let entry = state.recoveryEntriesByID.removeValue(
            forKey: recoveryID
        ) else {
            return nil
        }
        state.recoveryRescanRequested = true
        if let previousID = entry.previousID {
            state.recoveryEntriesByID[previousID]?.nextID = entry.nextID
        } else {
            state.recoveryHeadID = entry.nextID
        }
        if let nextID = entry.nextID {
            state.recoveryEntriesByID[nextID]?.previousID = entry.previousID
        } else {
            state.recoveryTailID = entry.previousID
        }
        return entry.action
    }

    private func enqueueRecoveryAction(
        _ action: @escaping TerminalSurfaceRuntimeOwnershipRecovery,
        onFailure: @escaping TerminalSurfaceRuntimeOwnershipRecoveryFailure,
        id recoveryID: UUID,
        in state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) {
        let previousID = state.recoveryTailID
        state.recoveryEntriesByID[recoveryID] =
            TerminalSurfaceRuntimeOwnershipRecoveryEntry(
                action: action,
                failure: onFailure,
                previousID: previousID,
                nextID: nil
            )
        if let previousID {
            state.recoveryEntriesByID[previousID]?.nextID = recoveryID
        } else {
            state.recoveryHeadID = recoveryID
        }
        state.recoveryTailID = recoveryID
    }

    private func recoveryCapacityIsOpen(
        in state: TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> Bool {
        state.recoveryEntriesByID.count
            + state.recoveryCapacityReservationIDs.count
            + state.pendingRecoveryFailureCount
            < maximumOwnerCount
    }

    private func overflowRecoveryCapacityIsOpen(
        in state: TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> Bool {
        !state.closeTeardownAllStalled
            && state.recoveryHeadID == nil
            && !state.recoveryGrantIsScheduled
            && recoveryCapacityIsOpen(in: state)
    }

    private func takeRecoveryRescanRequest(
        from state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> Bool {
        let requested = state.recoveryRescanRequested
        state.recoveryRescanRequested = false
        return requested
    }

    private func reserveOwnershipAndIngress(
        in state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> TerminalSurfaceRuntimeOwnershipReservation {
        let reservation = TerminalSurfaceRuntimeOwnershipReservation()
        state.reservationIDs.insert(reservation.id)
        state.ingressReservationIDs.insert(reservation.id)
        state.unclaimedOwnershipIngressReservationIDs.insert(reservation.id)
        return reservation
    }

    private func takeNextRecoveryGrant(
        from state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) -> TerminalSurfaceRuntimeOwnershipRecoveryGrant? {
        guard !state.closeTeardownDegraded,
              !state.closeTeardownAllStalled,
              !state.recoveryGrantIsScheduled,
              state.reservationIDs.count < maximumOwnerCount,
              state.ingressReservationIDs.count < maximumOwnerCount,
              let recoveryID = state.recoveryHeadID,
              let recoveryAction = removeRecoveryAction(
                  recoveryID,
                  from: &state
              ) else {
            return nil
        }
        let reservation = reserveOwnershipAndIngress(in: &state)
        state.recoveryGrantIsScheduled = true
        return TerminalSurfaceRuntimeOwnershipRecoveryGrant(
            action: recoveryAction,
            reservation: reservation
        )
    }

    private func schedule(
        _ recoveryGrant: TerminalSurfaceRuntimeOwnershipRecoveryGrant?
    ) {
        guard let recoveryGrant else { return }
        Task { @MainActor in
            recoveryGrant.action(recoveryGrant.reservation)
            recoveryGrantDidComplete()
        }
    }

    private func recoveryGrantDidComplete() {
        let grant = state.withLock { state in
            state.recoveryGrantIsScheduled = false
            let grant = takeNextRecoveryGrant(from: &state)
            _ = takeRecoveryRescanRequest(from: &state)
            return grant
        }
        schedule(grant)
        // The overflow FIFO can proceed only after every older primary grant
        // has run. Recheck it after each grant, including the final grant that
        // clears `recoveryGrantIsScheduled` without another state transition.
        recoveryRescanScheduler.requestRescan()
    }

#if DEBUG
    var debugCloseTeardownDegraded: Bool {
        state.withLock { $0.closeTeardownDegraded }
    }

    var debugCloseTeardownAllStalled: Bool {
        state.withLock { $0.closeTeardownAllStalled }
    }

    var debugOwnerCount: Int {
        state.withLock { $0.reservationIDs.count }
    }
#endif
}
