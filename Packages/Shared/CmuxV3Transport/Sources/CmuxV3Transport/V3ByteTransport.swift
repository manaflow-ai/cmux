import CMUXMobileCore
import CmuxV3Native
import Foundation

/// One RPC owner's stream. Closing this owner never retires another lane.
public actor V3ByteTransport: CmxByteTransport, CmxByteTransportLivenessObserving, CmxByteTransportClosureObserving {
    public typealias Establish = @Sendable (CmuxV3Native.Operation) async throws -> NativeStream
    public typealias Renew = @Sendable (NativeStream) async throws -> Void
    private let establish: Establish
    private let renew: Renew?
    private var stream: NativeStream?
    private var connecting: Task<NativeStream, any Error>?
    private var operation: CmuxV3Native.Operation?
    private var renewalTask: Task<Void, Never>?
    private var closed = false

    public init(establish: @escaping Establish, renew: Renew? = nil) {
        self.establish = establish
        self.renew = renew
    }
    public init(stream: NativeStream) {
        self.stream = stream
        self.establish = { _ in stream }
        self.renew = nil
    }
    deinit {
        operation?.cancel()
        connecting?.cancel()
        renewalTask?.cancel()
        stream?.close()
    }

    public func connect() async throws { _ = try await connected() }

    public func receive() async throws -> Data? {
        let stream = try await connected()
        let operation = CmuxV3Native.Operation()
        return try await withTaskCancellationHandler {
            do {
                let bytes = try await stream.receive(operation: operation)
                try Task.checkCancellation()
                guard !closed else { throw NativeError.Closed }
                return bytes
            } catch {
                close()
                throw error
            }
        } onCancel: { operation.cancel() }
    }

    public func send(_ data: Data) async throws {
        if data.isEmpty { return }
        let stream = try await connected()
        let operation = CmuxV3Native.Operation()
        try await withTaskCancellationHandler {
            do {
                try await stream.send(data: data, operation: operation)
                try Task.checkCancellation()
                guard !closed else { throw NativeError.Closed }
            } catch {
                close()
                throw error
            }
        } onCancel: { operation.cancel() }
    }

    /// Flush all queued bytes and send an ordered half-close marker. The
    /// reverse direction remains available for a response or final ack.
    public func finishSend() async throws {
        let stream = try await connected()
        let operation = CmuxV3Native.Operation()
        try await withTaskCancellationHandler {
            do {
                try await stream.finishSend(operation: operation)
                try Task.checkCancellation()
                guard !closed else { throw NativeError.Closed }
            } catch {
                if case NativeError.Cancelled = error { throw error }
                close()
                throw error
            }
        } onCancel: { operation.cancel() }
    }

    /// Permanently stop this transport's receive side while preserving sends.
    public func stopReceive() async {
        stream?.stopReceive()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        operation?.cancel()
        connecting?.cancel()
        operation = nil
        connecting = nil
        renewalTask?.cancel()
        renewalTask = nil
        stream?.close()
        stream = nil
    }

    public func isTransportClosed() -> Bool { closed || stream?.isClosed() == true }

    public func transportClosureObservation() -> CmxTransportClosureObservation? {
        guard let stream else { return nil }
        let operation = CmuxV3Native.Operation()
        return CmxTransportClosureObservation(waitUntilClosed: {
            _ = try? await stream.waitClosed(operation: operation)
        }, cancel: { operation.cancel() })
    }

    private func connected() async throws -> NativeStream {
        try Task.checkCancellation()
        guard !closed else { throw NativeError.Closed }
        if let stream { return stream }
        let task: Task<NativeStream, any Error>
        if let connecting { task = connecting }
        else {
            let operation = CmuxV3Native.Operation()
            let establish = self.establish
            self.operation = operation
            task = Task { try await establish(operation) }
            connecting = task
        }
        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                guard !closed, !Task.isCancelled else {
                    value.close()
                    close()
                    throw CancellationError()
                }
                stream = value
                connecting = nil
                operation = nil
                if let renew {
                    renewalTask = Task {
                        do { try await renew(value) }
                        catch { value.close() }
                    }
                }
                return value
            } catch {
                close()
                throw error
            }
        } onCancel: { Task { await self.close() } }
    }
}
