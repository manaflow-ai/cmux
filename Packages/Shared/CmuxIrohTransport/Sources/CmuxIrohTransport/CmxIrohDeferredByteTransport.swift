import CMUXMobileCore
import Foundation

/// Defers transport construction until the signed-in runtime finishes activation.
actor CmxIrohDeferredByteTransport:
    CmxByteTransport,
    CmxByteTransportClosureObserving,
    CmxByteTransportClosureObservationReadiness,
    CmxByteTransportContinuityIdentifying,
    CmxByteTransportLivenessObserving
{
    private let request: CmxByteTransportRequest
    private let provider: any CmxIrohDeferredTransportProviding
    private var connectTask: Task<any CmxByteTransport, any Error>?
    private var transport: (any CmxByteTransport)?
    private var closed = false
    private var closureObservationReadyWaiters: [CheckedContinuation<Void, Never>] = []

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
            connectTask = nil
            resumeClosureObservationReadyWaiters()
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
        resumeClosureObservationReadyWaiters()
        connectTask?.cancel()
        connectTask = nil
        let closing = transport
        transport = nil
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

    func waitUntilTransportClosureObservationIsReady() async -> Bool {
        guard !closed else { return false }
        if let transport {
            if let readiness = transport as?
                any CmxByteTransportClosureObservationReadiness {
                return await readiness.waitUntilTransportClosureObservationIsReady()
            }
            return transport is any CmxByteTransportClosureObserving
        }
        await withCheckedContinuation { continuation in
            if transport != nil || closed {
                continuation.resume()
            } else {
                closureObservationReadyWaiters.append(continuation)
            }
        }
        guard !closed, let transport else { return false }
        return transport is any CmxByteTransportClosureObserving
    }

    private func resumeClosureObservationReadyWaiters() {
        let waiters = closureObservationReadyWaiters
        closureObservationReadyWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func isTransportClosed() async -> Bool {
        if closed { return true }
        guard let transport else { return false }
        guard let observing = transport as? any CmxByteTransportLivenessObserving else {
            // The wrapper conforms to this protocol so the RPC layer can
            // inspect the activated transport. An underlying legacy transport
            // that cannot prove liveness is unknown, not proof of closure.
            // Keep the lane-scoped repair path in charge rather than tearing
            // down a healthy shared session on an unsupported observation.
            return false
        }
        return await observing.isTransportClosed()
    }
}
