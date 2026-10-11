import Foundation
import Network
import Synchronization
import Testing
@testable import CmuxNextAgentPane

/// cx-e9t, at the network boundary: a reply image URL whose name answers a public address when
/// the fetch checks it, and a private one at any later lookup (a DNS rebinding), must never reach
/// the private listener. The private listener is a real TCP listener on 127.0.0.1; it counts
/// every connection it accepts.
@Suite(.serialized)
struct AgentPaneSafeFetchRebindingTests {
    /// A TCP listener on 127.0.0.1 that accepts, counts and closes every connection.
    final class PrivateListener: @unchecked Sendable { // crash-allow: test support; the count holds the lock
        private let listener: NWListener
        private let queue = DispatchQueue(label: "cx-e9t.private-listener")
        private let accepted = Mutex(0)

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
        }

        var count: Int { accepted.withLock { $0 } }

        /// Starts the listener and returns its port once it is ready.
        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
                let resumed = Mutex(false)
                listener.newConnectionHandler = { [accepted] connection in
                    accepted.withLock { $0 += 1 }
                    connection.cancel()
                }
                listener.stateUpdateHandler = { [listener] state in
                    let port: UInt16?
                    let failure: (any Error)?
                    switch state {
                    case .ready: (port, failure) = (listener.port?.rawValue, nil)
                    case .failed(let error): (port, failure) = (nil, error)
                    default: return
                    }
                    guard resumed.withLock({ old in defer { old = true }; return !old }) else { return }
                    if let port { continuation.resume(returning: port) } else { continuation.resume(throwing: failure ?? CancellationError()) }
                }
                listener.start(queue: queue)
            }
        }

        func stop() { listener.cancel() }
    }

    @Test func aRebindingAnswerNeverReachesThePrivateListener() async throws {
        let listener = try PrivateListener()
        let port = try await listener.start()
        defer { listener.stop() }

        // The check's lookup says public; every later lookup (the system's) says 127.0.0.1.
        var fetch = AgentPaneSafeFetch()
        fetch.hostCheck = { _ in true }
        let result = await fetch.fetch(try #require(URL(string: "https://localhost:\(port)/a.png")))

        #expect((try? result.get()) == nil)
        #expect(listener.count == 0, "the fetch connected to the private listener after its check said public")
    }
}
