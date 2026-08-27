import Foundation

/// Caches GitHub CLI auth-header resolution between pull-request refresh passes.
actor GitHubAuthHeaderCache {
    private let successLifetime: TimeInterval
    private let failureLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var cachedHeader: String?
    private var resolvedAt: Date?

    init(
        successLifetime: TimeInterval = 5 * 60,
        failureLifetime: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.successLifetime = successLifetime
        self.failureLifetime = failureLifetime
        self.now = now
    }

    func header(resolve: @Sendable () async -> String?) async -> String? {
        let currentTime = now()
        if let resolvedAt {
            let lifetime = cachedHeader == nil ? failureLifetime : successLifetime
            if currentTime.timeIntervalSince(resolvedAt) < lifetime {
                return cachedHeader
            }
        }

        let header = await resolve()
        cachedHeader = header
        resolvedAt = currentTime
        return header
    }
}
