internal import CMUXMobileCore
internal import Foundation
internal import os

/// Linearizes new transport ownership against synchronous client retirement.
final class MobileRPCClientLifecycleGate: Sendable {
    struct IndependentEventAdmission: Sendable {
        fileprivate let revision: UInt64
    }

    struct ArtifactLaneAdmission: Sendable {
        fileprivate let revision: UInt64
    }

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

        let accepted = state.withLock { state in
            state.inFlightTransportAdmissions -= 1
            guard !state.retired, state.revision == admission else {
                startTransportDisposal(transport, state: &state)
                return false
            }
            return true
        }
        guard accepted else {
            throw MobileShellConnectionError.connectionClosed
        }
        return transport
    }

    func beginIndependentEventAdmission() throws -> IndependentEventAdmission {
        try state.withLock { state in
            guard !state.retired else {
                throw MobileShellConnectionError.connectionClosed
            }
            return IndependentEventAdmission(revision: state.revision)
        }
    }

    func finishIndependentEventAdmission(
        _ admission: IndependentEventAdmission,
        stream: CmxIndependentEventByteStream
    ) async throws -> CmxIndependentEventByteStream {
        let accepted = state.withLock { state in
            !state.retired && state.revision == admission.revision
        }
        guard accepted else {
            await Self.dispose(stream)
            throw MobileShellConnectionError.connectionClosed
        }
        return stream
    }

    func beginArtifactLaneAdmission() throws -> ArtifactLaneAdmission {
        try state.withLock { state in
            guard !state.retired else {
                throw MobileShellConnectionError.connectionClosed
            }
            return ArtifactLaneAdmission(revision: state.revision)
        }
    }

    func finishArtifactLaneAdmission(
        _ admission: ArtifactLaneAdmission,
        connection: any MobileArtifactLaneConnection
    ) async throws -> any MobileArtifactLaneConnection {
        let accepted = state.withLock { state in
            !state.retired && state.revision == admission.revision
        }
        guard accepted else {
            await connection.close()
            throw MobileShellConnectionError.connectionClosed
        }
        return connection
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

    private static func dispose(_ stream: CmxIndependentEventByteStream) async {
        let drain = Task {
            do {
                for try await _ in stream {}
            } catch {
                // Cancellation is the disposal mechanism for the abandoned stream.
            }
        }
        drain.cancel()
        _ = await drain.result
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
    ) {
        let disposalID = state.nextDisposalID
        state.nextDisposalID &+= 1
        // The handle is installed before this critical region is released. A
        // fast close can only report completion after that installation, so no
        // finished task can remain orphaned in the registry.
        state.transportDisposals[disposalID] = Task { [weak self] in
            await transport.close()
            self?.finishTransportDisposal(disposalID)
        }
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
