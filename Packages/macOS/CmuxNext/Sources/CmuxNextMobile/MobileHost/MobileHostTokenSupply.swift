import Foundation

/// Each child has one token lookup in flight. A startup handoff and a need_token
/// event join it, and neither holds up reading other control requests.
actor MobileHostTokenSupply {
    private let fetch: @Sendable (Bool) async throws -> String
    private let send: @Sendable (String) -> Void
    private let failed: @Sendable (any Error) -> Void
    private var task: Task<Void, Never>?
    private var last: String?
    private var stopped = false

    init(fetch: @escaping @Sendable (Bool) async throws -> String,
         send: @escaping @Sendable (String) -> Void,
         failed: @escaping @Sendable (any Error) -> Void) {
        self.fetch = fetch
        self.send = send
        self.failed = failed
    }

    func request() {
        guard !stopped, task == nil else { return }
        // task-owner: one lookup per child; stop cancels it, and supply checks cancellation before sending.
        task = Task { await supply() }
    }

    func stop() {
        stopped = true
        task?.cancel()
    }

    private func supply() async {
        defer { task = nil }
        do {
            var token = try await fetch(false)
            guard !stopped, !Task.isCancelled else { return }
            if token == last { token = try await fetch(true) }
            guard !stopped, !Task.isCancelled else { return }
            last = token
            send(token)
        } catch {
            if !stopped, !Task.isCancelled { failed(error) }
        }
    }
}
