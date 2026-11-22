import CmuxNextCompat
import Darwin
import Foundation

/// One wait for a socket descriptor to be readable or writable, with no thread held while it
/// waits (a dispatch source on the descriptor wakes it). It ends at readiness or at the caller's
/// cancel; a caller with a deadline of its own cancels at it. A daemon that exits closes its end,
/// which makes the descriptor readable (end of file), so the wait ends when the process on the
/// other side is gone: only an answer, an exit or the caller decides, never a timer (rule R5).
nonisolated final class AcpmuxSocketWait: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<Void, any Error>)
        case ended(Result<Void, any Error>)
    }

    private let state = Mutex(State.idle)

    private init() {}

    /// Waits until `descriptor` can be read (`forWrite` false) or written. Throws
    /// `CancellationError` when the caller's task is cancelled first.
    @concurrent static func ready(_ descriptor: Int32, forWrite: Bool) async throws {
        let wait = AcpmuxSocketWait()
        let queue = DispatchQueue(label: "cmux.next.agent-pane.acpmux-socket-wait", qos: .userInitiated)
        let source: any DispatchSourceProtocol
        if forWrite {
            source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        } else {
            source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        }
        source.setEventHandler { wait.finish(.success(())) }
        source.resume()
        let result: Result<Void, any Error>
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { wait.store($0) }
            } onCancel: {
                wait.finish(.failure(CancellationError()))
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        // The caller closes the descriptor after this returns: the source lets go of it first.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            source.setCancelHandler { done.resume() }
            source.cancel()
        }
        try result.get()
    }

    /// The continuation of the wait; an end that came first resumes it at once.
    private func store(_ continuation: CheckedContinuation<Void, any Error>) {
        let ended: Result<Void, any Error>? = state.withLock { state in
            if case .ended(let result) = state { return result }
            state = .waiting(continuation)
            return nil
        }
        if let ended { continuation.resume(with: ended) }
    }

    /// Ends the wait with `result`; only the first end counts.
    private func finish(_ result: Result<Void, any Error>) {
        let waiting: CheckedContinuation<Void, any Error>? = state.withLock { state in
            switch state {
            case .ended:
                return nil
            case .waiting(let continuation):
                state = .ended(result)
                return continuation
            case .idle:
                state = .ended(result)
                return nil
            }
        }
        waiting?.resume(with: result)
    }
}
