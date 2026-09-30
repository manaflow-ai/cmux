public import Foundation
import Network

/// A `MobileByteLane` over a Unix stream socket (the local cmux-tui daemon
/// or a Cloud link socket). Network.framework keeps every read and write off
/// the caller's thread; connect has a deadline so a wedged daemon is a typed
/// error, never a hang.
public final class UnixSocketLane: MobileByteLane {
    public enum Failure: Error, Equatable, Sendable {
        case connectTimedOut(path: String)
        case connectFailed(path: String, detail: String)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Connects to `path`, failing after `deadline`.
    public static func connect(path: String, deadline: Duration = .seconds(2)) async throws -> UnixSocketLane {
        let queue = DispatchQueue(label: "cmux.next.mobile.unix-lane")
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let lane = UnixSocketLane(connection: connection, queue: queue)
        // concurrency-allow: on timeout the catch cancels the NWConnection, which resumes waitUntilReady
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await lane.waitUntilReady(path: path) }
            group.addTask {
                // wakeup-allow: one-shot deadline (unix socket connect)
                try await Task.sleep(for: deadline)
                throw Failure.connectTimedOut(path: path)
            }
            defer { group.cancelAll() }
            do {
                try await group.next()
            } catch {
                connection.cancel()
                throw error
            }
        }
        return lane
    }

    private func waitUntilReady(path: String) async throws {
        let gate = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        gate.resume {
                            continuation.resume(throwing: Failure.connectFailed(path: path, detail: "\(error)"))
                        }
                    case .cancelled:
                        gate.resume { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    public func read(maximumBytes: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    // Complete, or an empty delivery with no error: the
                    // stream ended. Returning empty data made the splice
                    // pumps call read again at once, a loop without progress.
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func close() async {
        connection.cancel()
    }
}
