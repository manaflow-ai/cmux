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
        guard let port = await boundedValue(listenerReady, timeout: .seconds(2)) else {
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
        let registered = CloudLinkFirstValue<Bool>()
        let receive = Task {
            defer { finished.resolve(true) }
            _ = try? await client.receiveChunk(maximumLength: 1, onReceiveRegistered: { registered.resolve(true) })
        }
        defer { receive.cancel() }
        let receiveRegistered = await boundedValue(registered, timeout: .seconds(2)) == true
        #expect(receiveRegistered, "The Network receive must be registered before cancellation")
        guard receiveRegistered else { return }
        receive.cancel()

        let completed = await boundedValue(finished, timeout: .milliseconds(300)) == true
        #expect(completed, "Cancellation must release the registered receive")
        let underlyingConnectionCancelled = await boundedValue(connectionCancelled, timeout: .milliseconds(300)) == true
        #expect(underlyingConnectionCancelled)
        // Cleanup never waits on the receive task itself: a broken continuation
        // must fail the assertions above without stranding this test.

    }
}

private func boundedValue<Value: Sendable>(
    _ signal: CloudLinkFirstValue<Value>, timeout: Duration
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask { await signal.result }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
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
