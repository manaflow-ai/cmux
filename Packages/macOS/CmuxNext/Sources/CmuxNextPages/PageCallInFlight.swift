import CmuxNextSettings
import Foundation

/// One page call in flight: its work's task and the continuation the router answers. The first of
/// the work's end and a cancel answers it (once); a cancel also cancels the task.
@MainActor
final class PageCallInFlight {
    let op: String
    /// When the call arrived (`systemUptime`).
    let started = ProcessInfo.processInfo.systemUptime
    private var continuation: CheckedContinuation<JSONValue, any Error>?
    private var task: Task<Void, Never>?
    private var cancelled = false

    init(op: String) {
        self.op = op
    }

    func start(_ continuation: CheckedContinuation<JSONValue, any Error>, _ work: @escaping @MainActor () async throws -> JSONValue) {
        self.continuation = continuation
        guard !cancelled else { return finish(.failure(PageError.opCancelled)) }
        // task-owner: one page call; ends with its work or the page's cancel (navigation, tab close)
        task = Task { @MainActor [weak self] in
            let result: Result<JSONValue, any Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            self?.finish(result)
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        finish(.failure(PageError.opCancelled))
    }

    private func finish(_ result: Result<JSONValue, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
