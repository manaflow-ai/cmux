import Foundation

extension IrxControlByteTransport {
    func establishedPair() async throws -> (IrxConnection, IrxLaneStream) {
        try Task.checkCancellation()
        guard !isClosed else { throw IrxConnectionError.closed(nil) }
        if let pair {
            let connectionIsClosed = await pair.0.isConnectionClosed()
            guard !isClosed else { throw IrxConnectionError.closed(nil) }
            if connectionIsClosed {
                await close()
                throw IrxConnectionError.closed(nil)
            }
            return self.pair ?? pair
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                connectWaiters[id] = continuation
                guard connectInFlight == nil else { return }
                let task = Task { [establish] in try await establish() }
                connectInFlight = task
                Task {
                    await self.finishEstablishment(await task.result)
                }
            }
        } onCancel: {
            Task { await self.cancelEstablishmentWaiter(id) }
        }
    }

    private func cancelEstablishmentWaiter(_ id: UUID) async {
        guard let waiter = connectWaiters.removeValue(forKey: id) else { return }
        // The last owner releases the peer engine's waiter through the
        // establish task's cancellation handler. It never awaits native dial completion.
        if connectWaiters.isEmpty { await close() }
        waiter.resume(throwing: CancellationError())
    }

    private func finishEstablishment(
        _ result: Result<(IrxConnection, IrxLaneStream), any Error>
    ) async {
        connectInFlight = nil
        if isClosed {
            if case let .success((connection, lane)) = result {
                lastConnection = connection
                await closeEstablishedPair(connection: connection, lane: lane)
            }
            return
        }
        if case let .success(established) = result {
            lastConnection = established.0
            pair = established
            resumeClosureObservationReadyWaiters()
        }
        let waiters = connectWaiters.values
        connectWaiters = [:]
        for waiter in waiters { waiter.resume(with: result) }
    }

    func closeEstablishedPair(connection: IrxConnection, lane: IrxLaneStream) async {
        let connectionWasAlreadyClosed = await connection.isConnectionClosed()
        let retiresConnection = !controlTerminationObserved && !connectionWasAlreadyClosed
        let terminationCode: IrxCloseCode = controlTerminationObserved ? .hostShutdown : closeCode
        if !retiresConnection, !connectionWasAlreadyClosed {
            await connection.close(code: terminationCode, origin: .remote)
        }
        await onClose?(connection, terminationCode, retiresConnection)
        // Close the connection before retiring native streams: a stream read
        // can ignore task cancellation and hold its FFI stream mutex indefinitely.
        if retiresConnection {
            await connection.close(code: closeCode, origin: .local)
        }
        await lane.writer.finish()
        await lane.reader.stop()
    }
}
