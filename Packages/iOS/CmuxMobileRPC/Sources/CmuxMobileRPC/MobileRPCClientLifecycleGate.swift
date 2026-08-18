internal import CMUXMobileCore
internal import Foundation
internal import os

/// Linearizes new transport ownership against synchronous client retirement.
final class MobileRPCClientLifecycleGate: Sendable {
    private struct State: Sendable {
        var retired = false
        var revision: UInt64 = 0
        var inFlightTransportAdmissions = 0
        var nextDisposalID: UInt64 = 0
        var transportDisposals: [UInt64: Task<Void, Never>] = [:]
        var retirementWaiters: [CheckedContinuation<Void, Never>] = []
    }

    // lint:allow lock - `makeTransport` and `retire` are synchronous by contract.
    // Critical regions only mutate counters/task handles; factories and async
    // transport cleanup always run after admission state has been released.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func makeTransport(
        _ make: () throws -> any CmxByteTransport
    ) throws -> any CmxByteTransport {
        let admission = try state.withLock { state in
            guard !state.retired else {
                throw MobileShellConnectionError.connectionClosed
            }
            state.inFlightTransportAdmissions += 1
            return state.revision
        }

        let transport: any CmxByteTransport
        do {
            transport = try make()
        } catch {
            completeFailedTransportAdmission()
            throw error
        }

        let rejectedDisposal: Task<Void, Never>? =
            state.withLock { state in
                state.inFlightTransportAdmissions -= 1
                guard !state.retired,
                      state.revision == admission else {
                    return startTransportDisposal(
                        transport,
                        state: &state
                    )
                }
                return nil
            }
        if let rejectedDisposal {
            throw MobileRPCRejectedTransportDisposal(
                task: rejectedDisposal
            )
        }
        return transport
    }

    func retire() {
        let waiters = state.withLock { state in
            state.retired = true
            state.revision &+= 1
            return Self.takeRetirementWaitersIfQuiescent(state: &state)
        }
        Self.resume(waiters)
    }

    /// Waits until every transport factory admitted before retirement has
    /// returned and every resulting stale transport has finished closing.
    ///
    /// Synchronous ownership changes still call ``retire()`` without waiting;
    /// this async boundary exists for deterministic teardown and verification.
    func waitForRetiredTransportDisposals() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !Self.isRetirementQuiescent(state) else { return true }
                state.retirementWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func completeFailedTransportAdmission() {
        let waiters = state.withLock { state in
            state.inFlightTransportAdmissions -= 1
            return Self.takeRetirementWaitersIfQuiescent(state: &state)
        }
        Self.resume(waiters)
    }

    private func startTransportDisposal(
        _ transport: any CmxByteTransport,
        state: inout State
    ) -> Task<Void, Never> {
        let disposalID = state.nextDisposalID
        state.nextDisposalID &+= 1
        // The handle is installed before this critical region is released. A
        // fast close can only report completion after that installation, so no
        // finished task can remain orphaned in the registry.
        let task = Task { [weak self] in
            await transport.close()
            self?.finishTransportDisposal(disposalID)
        }
        state.transportDisposals[disposalID] = task
        return task
    }

    private func finishTransportDisposal(_ disposalID: UInt64) {
        let waiters = state.withLock { state in
            state.transportDisposals.removeValue(forKey: disposalID)
            return Self.takeRetirementWaitersIfQuiescent(state: &state)
        }
        Self.resume(waiters)
    }

    private static func isRetirementQuiescent(_ state: State) -> Bool {
        state.retired
            && state.inFlightTransportAdmissions == 0
            && state.transportDisposals.isEmpty
    }

    private static func takeRetirementWaitersIfQuiescent(
        state: inout State
    ) -> [CheckedContinuation<Void, Never>] {
        guard isRetirementQuiescent(state) else { return [] }
        let waiters = state.retirementWaiters
        state.retirementWaiters.removeAll()
        return waiters
    }

    private static func resume(_ waiters: [CheckedContinuation<Void, Never>]) {
        for waiter in waiters {
            waiter.resume()
        }
    }
}
