import Foundation
import Network
import Testing

@testable import CmuxCloud

struct NWConnectionAsyncTests {
    @Test("cancelling a pending receive cancels the underlying connection")
    func receiveCancellationDoesNotLeaveAStalledContinuation() async throws {
        let queue = DispatchQueue(label: "cmux.tests.cloud-connection-cancellation")
        let listener = try NWListener(using: .tcp)
        let listenerReady = CloudLinkFirstValue<UInt16>()
        let accepted = ConnectionHolder()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                listenerReady.resolve(listener.port?.rawValue)
            case .failed, .cancelled:
                listenerReady.resolve(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            accepted.store(connection)
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer {
            listener.cancel()
            accepted.cancel()
        }
        guard let port = await listenerReady.result else {
            Issue.record("The test listener did not become ready")
            return
        }

        let client = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
        defer { client.cancel() }
        try await client.startAndWaitUntilReady(queue: queue)
        let connectionCancelled = CloudLinkFirstValue<Bool>()
        client.stateUpdateHandler = { state in
            if case .cancelled = state {
                connectionCancelled.resolve(true)
            }
        }

        let finished = CloudLinkFirstValue<Bool>()
        let receive = Task {
            defer { finished.resolve(true) }
            _ = try? await client.receiveChunk(maximumLength: 1)
        }
        receive.cancel()

        // A stalled continuation must finish from task cancellation. Keep a
        // bounded fallback so a regression cannot strand this test forever;
        // the fallback is deliberately after the assertion's deadline.
        let completed = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await finished.result }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(300))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
        if !completed {
            client.cancel()
            _ = await finished.result
        }
        let underlyingConnectionCancelled = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await connectionCancelled.result }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(300))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
        #expect(completed)
        #expect(underlyingConnectionCancelled)
        _ = await receive.result
    }
}

private final class ConnectionHolder: @unchecked Sendable {
    private var connection: NWConnection?
    private let lock = NSLock()

    func store(_ connection: NWConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.cancel()
    }
}
