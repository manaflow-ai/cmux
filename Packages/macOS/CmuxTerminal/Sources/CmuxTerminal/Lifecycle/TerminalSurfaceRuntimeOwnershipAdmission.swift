import Foundation
internal import os

typealias TerminalSurfaceRuntimeOwnershipRecovery =
    @MainActor @Sendable (TerminalSurfaceRuntimeOwnershipReservation) -> Void

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
            TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler =
                TerminalSurfaceRuntimeOwnershipRecoveryRescanScheduler()
    ) {
        precondition(
            maximumOwnerCount >= TerminalSurfaceRuntimeTeardownCoordinator
                .maximumConcurrentCloseTeardownCount,
            "native surface ownership must cover every close worker"
        )
        self.maximumOwnerCount = maximumOwnerCount
        self.recoveryRescanScheduler = recoveryRescanScheduler
    }

    func reserve() -> TerminalSurfaceRuntimeOwnershipReservation? {
        state.withLock { state in
            guard !state.closeTeardownDegraded,
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
                return (.deferred, claimedCapacity)
            }
            guard claimedCapacity || recoveryCapacityIsOpen(in: state) else {
                return (.rejected, false)
            }
            enqueueRecoveryAction(
                onRecovery,
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
            guard recoveryCapacityIsOpen(in: state) else { return nil }
            let reservation =
                TerminalSurfaceRuntimeOwnershipRecoveryCapacityReservation()
            state.recoveryCapacityReservationIDs.insert(reservation.id)
            return reservation
        }
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
        id recoveryID: UUID,
        in state: inout TerminalSurfaceRuntimeOwnershipAdmissionState
    ) {
        let previousID = state.recoveryTailID
        state.recoveryEntriesByID[recoveryID] =
            TerminalSurfaceRuntimeOwnershipRecoveryEntry(
                action: action,
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
            < maximumOwnerCount
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
        let output = state.withLock { state in
            state.recoveryGrantIsScheduled = false
            let grant = takeNextRecoveryGrant(from: &state)
            return (grant, takeRecoveryRescanRequest(from: &state))
        }
        schedule(output.0)
        if output.1 {
            recoveryRescanScheduler.requestRescan()
        }
    }

#if DEBUG
    var debugCloseTeardownDegraded: Bool {
        state.withLock { $0.closeTeardownDegraded }
    }

    var debugOwnerCount: Int {
        state.withLock { $0.reservationIDs.count }
    }
#endif
}
