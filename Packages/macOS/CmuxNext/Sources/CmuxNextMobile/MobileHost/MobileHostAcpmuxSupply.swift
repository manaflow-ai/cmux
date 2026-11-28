import Foundation

/// One endpoint lookup per child. Startup and refresh requests share it without
/// holding up the control pipe's pairing, token or status events.
actor MobileHostAcpmuxSupply {
    typealias Endpoint = (url: URL, token: String)

    private let fetch: @Sendable () async -> Endpoint?
    private let send: @Sendable (Endpoint) -> Void
    private var task: Task<Void, Never>?
    private var stopped = false

    init(fetch: @escaping @Sendable () async -> Endpoint?, send: @escaping @Sendable (Endpoint) -> Void) {
        self.fetch = fetch
        self.send = send
    }

    @discardableResult
    func request() -> Task<Void, Never>? {
        guard !stopped else { return nil }
        if let task { return task }
        // task-owner: one lookup per child; stop cancels it and suppresses a late answer.
        let next = Task { await supply() }
        task = next
        return next
    }

    func stop() {
        stopped = true
        task?.cancel()
    }

    private func supply() async {
        defer { task = nil }
        guard !stopped, !Task.isCancelled else { return }
        guard let endpoint = await fetch(), !stopped, !Task.isCancelled else { return }
        send(endpoint)
    }
}
