import Foundation
import Network
import CmuxNextCompat
import CmuxNextRemoteFetch
import Testing
@testable import CmuxNextAgentPane

/// cx-e9t, at the network boundary: a reply image URL whose name answers a public address when
/// the fetch checks it, and a private one at any later lookup (a DNS rebinding), must never reach
/// the private listener. The private listener is a real TCP listener on 127.0.0.1; it counts
/// every connection it accepts.
@Suite(.serialized)
struct AgentPaneSafeFetchRebindingTests {
    /// A TCP listener on 127.0.0.1 that accepts, counts and closes every connection.
    final class PrivateListener: @unchecked Sendable { // crash-allow: test support; the state holds the lock
        private let listener: NWListener
        private let queue = DispatchQueue(label: "cx-e9t.private-listener")
        /// Accepted connections, and whether `start` has answered.
        private let state = Mutex((accepted: 0, answered: false))

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
        }

        var count: Int { state.withLock { $0.accepted } }

        /// Starts the listener and returns its port once it is ready.
        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
                listener.newConnectionHandler = { [self] connection in
                    state.withLock { $0.accepted += 1 }
                    connection.cancel()
                }
                listener.stateUpdateHandler = { [self] update in
                    let port: UInt16?
                    let failure: (any Error)?
                    switch update {
                    case .ready: (port, failure) = (listener.port?.rawValue, nil)
                    case .failed(let error): (port, failure) = (nil, error)
                    default: return
                    }
                    let first = state.withLock { state -> Bool in
                        defer { state.answered = true }
                        return !state.answered
                    }
                    guard first else { return }
                    if let port { continuation.resume(returning: port) } else { continuation.resume(throwing: failure ?? CancellationError()) }
                }
                listener.start(queue: queue)
            }
        }

        func stop() { listener.cancel() }
    }

    /// A DNS stub that answers a public address at the first lookup and 127.0.0.1 at every later
    /// one, and counts the lookups.
    nonisolated final class RebindingResolver: RemoteAddressResolving, @unchecked Sendable { // crash-allow: test support; the count holds the lock
        private let lookups = Mutex(0)

        var count: Int { lookups.withLock { $0 } }

        func resolve(_ host: String) async throws -> [RemoteAddress] {
            let first = lookups.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            return [first ? .v4([1, 1, 1, 1]) : .v4([127, 0, 0, 1])]
        }
    }

    @Test func aRebindingAnswerNeverReachesThePrivateListener() async throws {
        let listener = try PrivateListener()
        let port = try await listener.start()
        defer { listener.stop() }

        // The check's lookup says public; every later lookup says 127.0.0.1.
        let dns = RebindingResolver()
        var fetch = AgentPaneSafeFetch()
        fetch.guarded.resolver = dns
        fetch.guarded.timeout = .seconds(3)
        // `127.1` is a name to the fetch (not a canonical literal) and the stub answers it; a
        // transport that connected by name would hand it to the system resolver, which turns it
        // into 127.0.0.1, the private listener.
        let result = await fetch.fetch(try #require(URL(string: "https://127.1:\(port)/a.png")))

        #expect((try? result.get()) == nil)
        #expect(listener.count == 0, "the fetch connected to the private listener after its check said public")
        #expect(dns.count == 1, "the fetch looked the name up again after its check")
    }
}
