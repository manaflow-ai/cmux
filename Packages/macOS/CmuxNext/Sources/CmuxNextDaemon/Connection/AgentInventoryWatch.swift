import Foundation

/// One cache subscription lifecycle, pinned to one admitted control transport.
///
/// Obtain this manager from ``DaemonConnection/agentInventoryWatch(expectedMachineID:)``.
/// Cancellation retires a pending admission only after recovering its receipt.
/// Retirement precedes readmission; a failed admission or cleanup remains failed
/// on this manager, so uncertainty cannot create a second lease. The route owner
/// must invalidate callbacks before retirement and match receipts to its epoch.
public actor AgentInventoryWatch {
    private let transport: LineTransport
    private let machine: ResourceID
    private var generation: UInt64 = 0
    private var pending: Task<AgentInventoryWatchReceipt, any Error>?
    private var active: AgentInventoryWatchReceipt?
    private var retirement: Task<Void, any Error>?

    init(transport: LineTransport, machine: ResourceID) {
        self.transport = transport
        self.machine = machine
    }

    /// Enables this transport's watch, sharing an existing admission or live receipt.
    ///
    /// The bounded native operation continues after caller cancellation so its
    /// receipt can be conditionally retired. No new transport is opened.
    /// - Returns: The canonical owner, lease ID and exact initial revision.
    /// - Throws: Cancellation, owner mismatch, native refusal or transport failure.
    public func enable() async throws -> AgentInventoryWatchReceipt {
        try Task.checkCancellation()
        try await finishRetirement()
        try Task.checkCancellation()
        if let active { return active }
        if pending == nil {
            generation += 1
            let transport = transport, machine = machine
            // task-owner: retained until receipt/retirement, bounded by the owner-read deadline
            pending = Task {
                let receipt = try await DaemonConnection.perform(MachineAgentInventoryWatchRequest(expectedMachineID: machine),
                                                               on: transport, timeout: .seconds(15))
                guard receipt.machine == machine else { throw DaemonError.malformedResponse("Inventory watch receipt owner mismatch") }
                return receipt
            }
        }
        guard let admission = pending else { throw DaemonError.notConnected }
        let admittedGeneration = generation
        return try await withTaskCancellationHandler {
            let receipt = try await admission.value
            if Task.isCancelled {
                try? await retire(expectedGeneration: admittedGeneration)
                throw CancellationError()
            }
            guard generation == admittedGeneration else { throw CancellationError() }
            pending = nil
            active = receipt
            return receipt
        } onCancel: {
            // task-owner: cancellation invalidates only this generation; retirement retains the bounded RPC
            Task { try? await self.retire(expectedGeneration: admittedGeneration) }
        }
    }

    /// Invalidates admission and conditionally retires its receipt on the captured transport.
    ///
    /// Idempotent; pending enable is awaited without cancelling its native
    /// waiter. A failed cleanup is retained and blocks subsequent enables.
    /// - Throws: Admission or cleanup failure; no unfenced fallback is sent.
    public func disable() async throws {
        try await retire(expectedGeneration: nil)
    }

    private func retire(expectedGeneration: UInt64?) async throws {
        if let expectedGeneration, expectedGeneration != generation { return }
        if retirement != nil { return try await finishRetirement() }
        guard pending != nil || active != nil else { return }
        generation += 1
        let admission = pending, receipt = active, transport = transport, machine = machine
        pending = nil
        active = nil
        // task-owner: cleanup survives caller cancellation, retains receipt and original transport, bounded per request
        retirement = Task {
            let accepted: AgentInventoryWatchReceipt
            if let receipt { accepted = receipt }
            else if let admission { accepted = try await admission.value }
            else { throw DaemonError.notConnected }
            _ = try await DaemonConnection.perform(MachineAgentInventoryUnwatchRequest(expectedMachineID: machine, expectedWatchID: accepted.watchID),
                                                  on: transport, timeout: .seconds(15))
        }
        try await finishRetirement()
    }

    private func finishRetirement() async throws {
        guard let retiring = retirement else { return }
        let retiringGeneration = generation
        try await retiring.value
        if generation == retiringGeneration { retirement = nil }
    }
}
