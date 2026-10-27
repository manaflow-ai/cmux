import CmuxNextSettings
import class CmuxSafeConcurrency.OnceContinuation
import Foundation

/// One page call in flight: its work's task and the continuation the router answers. The first of
/// the work's end and a cancel answers it (once); a cancel also cancels the task.
@MainActor
final class PageCallInFlight {
    let op: String
    /// When the call arrived (`systemUptime`).
    let started = ProcessInfo.processInfo.systemUptime
    private var continuation: OnceContinuation<JSONValue, any Error>?
    private var task: Task<Void, Never>?
    private var cancelled = false

    init(op: String) {
        self.op = op
    }

    func start(_ continuation: OnceContinuation<JSONValue, any Error>, _ work: @escaping @MainActor () async throws -> JSONValue) {
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

/// Events a provider sends before its subscription is registered and answered: held in order,
/// then released once, after which events go straight to the page.
@MainActor
final class PageEarlyEvents {
    private var held: [JSONValue]? = []

    /// Whether any event is held (the subscription is not released and something arrived).
    var isHolding: Bool { !(held?.isEmpty ?? true) }

    /// Holds `data` while the subscription is not released yet; false once it is.
    func hold(_ data: JSONValue) -> Bool {
        guard held != nil else { return false }
        held?.append(data)
        return true
    }

    /// The held events, oldest first; later events are not held.
    func release() -> [JSONValue] {
        defer { held = nil }
        return held ?? []
    }
}
