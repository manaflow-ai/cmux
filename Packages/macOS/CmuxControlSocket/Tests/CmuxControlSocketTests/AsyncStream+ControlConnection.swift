import CmuxControlSocket
import Darwin

extension AsyncStream where Element == ControlConnection {
    /// Waits for a connection with a real deadline; cancellation terminates
    /// continuation-backed AsyncStream iteration and drains both child tasks.
    /// Any descriptor delivered after the deadline is closed by this owner.
    func nextControlConnection(timeout: Duration = .seconds(5)) async throws -> ControlConnection {
        let connection = await withTaskGroup(of: ControlConnection?.self) { group in
            group.addTask {
                var iterator = self.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            // AsyncStream.next() is cancellation-aware. Draining also owns a
            // connection that loses the race to the deadline after being read.
            for await remaining in group {
                if let remaining { close(remaining.socket) }
            }
            return first
        }
        if Task.isCancelled {
            if let connection { close(connection.socket) }
            throw CancellationError()
        }
        guard let connection else { throw SocketConnectionWaitError.timedOut }
        return connection
    }
}
