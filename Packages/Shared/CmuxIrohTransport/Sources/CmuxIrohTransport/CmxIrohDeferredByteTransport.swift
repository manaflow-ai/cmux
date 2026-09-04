import CMUXMobileCore
import Foundation

/// Defers transport construction until the signed-in runtime finishes activation.
actor CmxIrohDeferredByteTransport:
    CmxByteTransport,
    CmxByteTransportClosureObserving,
    CmxByteTransportContinuityIdentifying,
    CmxByteTransportPathObserving
{
    private let request: CmxByteTransportRequest
    private let provider: any CmxIrohDeferredTransportProviding
    private var connectTask: Task<any CmxByteTransport, any Error>?
    private var transport: (any CmxByteTransport)?
    private var transportGeneration = UUID()
    private var pathObservationTasks: [UUID: Task<Void, Never>] = [:]
    private var pathObservationContinuations:
        [UUID: AsyncStream<CmxTransportPath>.Continuation] = [:]
    private var closed = false

    init(
        request: CmxByteTransportRequest,
        provider: any CmxIrohDeferredTransportProviding
    ) {
        self.request = request
        self.provider = provider
    }

    func connect() async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        if transport != nil { return }

        let task: Task<any CmxByteTransport, any Error>
        if let connectTask {
            task = connectTask
        } else {
            let request = request
            let provider = provider
            task = Task {
                let transport = try await provider.transport(for: request)
                do {
                    try await transport.connect()
                    try Task.checkCancellation()
                    return transport
                } catch {
                    await transport.close()
                    throw error
                }
            }
            connectTask = task
        }

        do {
            let connected = try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() }
            )
            guard !closed else {
                await connected.close()
                throw CmxIrohByteTransportError.alreadyClosed
            }
            transport = connected
            transportGeneration = UUID()
            connectTask = nil
            await startPendingPathObservations(on: connected)
        } catch {
            connectTask = nil
            throw error
        }
    }

    func receive() async throws -> Data? {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let transport else { throw CmxIrohByteTransportError.notConnected }
        return try await transport.receive()
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CmxIrohByteTransportError.alreadyClosed }
        guard let transport else { throw CmxIrohByteTransportError.notConnected }
        try await transport.send(data)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        connectTask?.cancel()
        connectTask = nil
        let closing = transport
        transport = nil
        transportGeneration = UUID()
        finishAllPathObservations()
        await closing?.close()
    }

    func transportContinuityID() async -> UInt64? {
        guard let identifying = transport as? any CmxByteTransportContinuityIdentifying else {
            return nil
        }
        return await identifying.transportContinuityID()
    }

    func transportClosureObservation() async -> CmxTransportClosureObservation? {
        guard let observing = transport as? any CmxByteTransportClosureObserving else {
            return nil
        }
        return await observing.transportClosureObservation()
    }

    func currentTransportPath() async -> CmxTransportPath {
        guard let transport,
              let observing = transport as? any CmxByteTransportPathObserving else {
            return .unavailable
        }
        return await observing.currentTransportPath()
    }

    func transportPathChanges() async -> AsyncStream<CmxTransportPath> {
        guard !closed else {
            return unavailablePathStream()
        }
        let observationID = UUID()
        // Keep a continuation pending only while the deferred transport has
        // not been created yet. Once a concrete transport exists but cannot
        // observe paths, finish immediately instead of leaving the shell's
        // observation task suspended forever.
        if let transport,
           let observing = transport as? any CmxByteTransportPathObserving {
            let stream = AsyncStream<CmxTransportPath>(
                bufferingPolicy: .bufferingNewest(1)
            ) { continuation in
                pathObservationContinuations[observationID] = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.cancelPathObservation(observationID) }
                }
            }
            await attachPathObservation(
                observationID,
                observing: observing,
                generation: transportGeneration
            )
            return stream
        }
        if transport != nil {
            return unavailablePathStream()
        }
        let stream = AsyncStream<CmxTransportPath>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            pathObservationContinuations[observationID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.cancelPathObservation(observationID) }
            }
        }
        return stream
    }

    private func unavailablePathStream() -> AsyncStream<CmxTransportPath> {
        AsyncStream { continuation in
            continuation.yield(.unavailable)
            continuation.finish()
        }
    }

    private func startPendingPathObservations(
        on transport: any CmxByteTransport
    ) async {
        let generation = transportGeneration
        guard let observing = transport as? any CmxByteTransportPathObserving else {
            let pendingIDs = Array(pathObservationContinuations.keys)
            for id in pendingIDs {
                pathObservationContinuations[id]?.yield(.unavailable)
                finishPathObservation(id)
            }
            return
        }
        for id in Array(pathObservationContinuations.keys) {
            await attachPathObservation(
                id,
                observing: observing,
                generation: generation
            )
        }
    }

    private func attachPathObservation(
        _ id: UUID,
        observing: any CmxByteTransportPathObserving,
        generation: UUID
    ) async {
        guard pathObservationTasks[id] == nil,
              pathObservationContinuations[id] != nil else { return }
        let changes = await observing.transportPathChanges()
        guard !closed,
              transportGeneration == generation,
              pathObservationContinuations[id] != nil else {
            // The wrapper may have closed or replaced its concrete transport
            // while the underlying stream was being requested. Do not leave
            // the caller's continuation orphaned in that race.
            finishPathObservation(id)
            return
        }
        let task = Task { [weak self] in
            for await path in changes {
                guard !Task.isCancelled else { return }
                await self?.yieldPathObservation(id, value: path)
            }
            await self?.finishPathObservation(id)
        }
        pathObservationTasks[id] = task
    }

    private func cancelPathObservation(_ id: UUID) {
        pathObservationTasks.removeValue(forKey: id)?.cancel()
        pathObservationContinuations.removeValue(forKey: id)?.finish()
    }

    private func finishPathObservation(_ id: UUID) {
        pathObservationTasks[id] = nil
        pathObservationContinuations.removeValue(forKey: id)?.finish()
    }

    private func yieldPathObservation(
        _ id: UUID,
        value: CmxTransportPath
    ) {
        pathObservationContinuations[id]?.yield(value)
    }

    private func finishAllPathObservations() {
        for task in pathObservationTasks.values {
            task.cancel()
        }
        pathObservationTasks.removeAll()
        for continuation in pathObservationContinuations.values {
            continuation.finish()
        }
        pathObservationContinuations.removeAll()
    }
}
