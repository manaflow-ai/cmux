import CmuxNextCompat
import CmuxNextRemoteView
import Foundation
import Network

/// The link bridge's Unix socket as the remote view transport's byte stream.
nonisolated enum MacScreenUnixStream {
    static func open(path: String) async throws -> RemoteRdByteStream {
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        // The stream's bytes: the next decoded frame waits for them.
        let queue = DispatchQueue(label: "com.cmuxterm.mac-screen.rd-socket", qos: .userInitiated)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            connection.stateUpdateHandler = { state in
                let resume: (Result<Void, any Error>) -> Void = { result in
                    guard !resumed.withLock({ done in defer { done = true }; return done }) else { return }
                    continuation.resume(with: result)
                }
                switch state {
                case .ready: resume(.success(()))
                case let .failed(error), let .waiting(error): resume(.failure(error))
                case .cancelled: resume(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        return RemoteRdByteStream(
            read: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                        // An empty read only comes with the end of the stream or an error.
                        continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 } ?? (isComplete || error != nil ? nil : Data()))
                    }
                }
            },
            write: { bytes in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                }
            },
            close: { connection.cancel() }
        )
    }
}
