import Foundation

/// Captures the login env once per app launch; concurrent callers share it.
actor LoginEnvironmentCache {
    static let shared = LoginEnvironmentCache(store: .standard(), capture: { timeout in
        await LoginEnvironment.shared.capture(timeout: timeout)
    })

    private let store: LoginEnvironmentStore?
    private let capture: @Sendable (Duration) async -> [String: String]?
    private let waitTimeout: Duration
    private let refreshTimeout: Duration
    private var task: Task<[String: String]?, Never>?

    /// `capture` runs the login shell with the given deadline.
    init(
        store: LoginEnvironmentStore?,
        waitTimeout: Duration = .seconds(5),
        refreshTimeout: Duration = .seconds(30),
        capture: @escaping @Sendable (Duration) async -> [String: String]?
    ) {
        self.store = store
        self.capture = capture
        self.waitTimeout = waitTimeout
        self.refreshTimeout = refreshTimeout
    }

    /// Starts the capture now.
    func start() { _ = capturing() }

    /// The environment for a new terminal.
    func value() async -> [String: String]? {
        await capturing().value
    }

    /// The environment for starting the daemon.
    func immediate() async -> [String: String]? {
        await capturing().value
    }

    private func capturing() -> Task<[String: String]?, Never> {
        if let task { return task }
        let capture = capture
        let timeout = waitTimeout
        let task = Task { await capture(timeout) }
        self.task = task
        return task
    }
}
