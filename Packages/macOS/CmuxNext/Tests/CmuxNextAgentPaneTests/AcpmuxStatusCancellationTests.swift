import Foundation
import Network
import Testing
@testable import CmuxNextAgentPane

/// A caller cancelling a stalled unix RPC closes its connection before the RPC's long deadline.
struct AcpmuxStatusCancellationTests {
    @Test(.timeLimit(.minutes(1))) func cancellationInterruptsAStalledReply() async throws {
        let path = "/tmp/cmux-warm-cancel-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let (ready, readyEvents) = AsyncStream<Bool>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: readyEvents.yield(true)
            case .failed, .cancelled: readyEvents.yield(false)
            default: break
            }
        }
        let (connections, accepted) = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { accepted.yield($0) }
        listener.start(queue: .global(qos: .userInitiated))
        for await isReady in ready { try #require(isReady); break }
        let request = Task {
            do {
                _ = try await AcpmuxStatusClient.call(socketPath: path, method: "_acpmux/warm", deadline: .seconds(60))
                return false
            } catch { return true }
        }
        defer { request.cancel() }
        var peer: NWConnection?
        for await connection in connections { peer = connection; break }
        let connection = try #require(peer)
        defer { connection.cancel() }
        try await AcpmuxStatusClient.start(connection)
        _ = try #require(try await AcpmuxStatusClient.receive(on: connection))
        // The initialize request arrived, but this peer never answers it.
        request.cancel()
        let cancelled = try await withAgentPaneDeadline(.seconds(2), label: "cancelled socket returns",
                                                        onTimeout: { connection.cancel() }) {
            await request.value
        }
        #expect(cancelled)
    }
}
