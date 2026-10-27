#if canImport(Network)
public import Foundation
import Network
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// A `MobileByteLane` over a Unix stream socket (the local cmux-tui daemon
/// or a Cloud link socket). Network.framework keeps every read and write off
/// the caller's thread; connect has a deadline so a wedged daemon is a typed
/// error, never a hang. Linux, which has no Network.framework, has its own
/// lane of the same surface (UnixSocketLane+Linux.swift).
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
        let queue = DispatchQueue(label: "cmux.next.mobile.unix-lane", qos: .userInitiated)
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let lane = UnixSocketLane(connection: connection, queue: queue)
        // concurrency-allow: on timeout the catch cancels the NWConnection, which resumes waitUntilReady
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await lane.waitUntilReady(path: path) }
            group.addTask {
                // wakeup-allow: deadline of one unix socket connect: a task-group race with the connect, not a DemandTimer
                try await Task.sleep(for: deadline, tolerance: WakeLeeway.window(delay: deadline).tolerance)
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
        try await withTaskCancellationHandler {
            // Not cancellable itself: the cancel handler cancels the connection, whose `.cancelled` answers.
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
                // The first ready, failed or cancelled state answers. Network calls this handler on `queue`
                // one state at a time, so dropping it there leaves no later state to answer again.
                connection.stateUpdateHandler = { [weak connection] state in
                    switch state {
                    case .ready:
                        connection?.stateUpdateHandler = nil
                        continuation.resume(returning: ())
                    case .failed(let error), .waiting(let error):
                        connection?.stateUpdateHandler = nil
                        continuation.resume(throwing: Failure.connectFailed(path: path, detail: "\(error)"))
                    case .cancelled:
                        connection?.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
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
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Data?, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // Complete, or an empty delivery with no error: the
                // stream ended. Returning empty data made the splice
                // pumps call read again at once, a loop without progress.
                continuation.resume(returning: nil)
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            })
        }
    }

    public func close() async {
        connection.cancel()
    }
}
#endif
