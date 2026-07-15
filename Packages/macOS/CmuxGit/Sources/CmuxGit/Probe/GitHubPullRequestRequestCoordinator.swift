import Foundation

/// Process-scoped transport policy for GitHub pull-request probes.
///
/// A single instance is shared by every app window. It owns the reusable
/// session, conditional-response cache, rate-limit deadline, in-flight request
/// coalescing, and a one-request transport queue. Keeping these concerns here
/// prevents per-window pollers from independently consuming the same GitHub
/// rate-limit pool.
actor GitHubPullRequestRequestCoordinator {
    private struct CachedResponse: Sendable {
        let etag: String
        let data: Data
    }

    private struct InFlightRequest: Sendable {
        let id: UUID
        let task: Task<WorkspacePullRequestHTTPResponse?, Never>
    }

    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cachedResponseByEndpoint: [String: CachedResponse] = [:]
    private var inFlightRequestByEndpoint: [String: InFlightRequest] = [:]
    private var transportTail: Task<Void, Never>?
    private var rateLimitRetryDate: Date?

    init(
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = max(PullRequestProbeService.probeTimeout, 8)
            configuration.timeoutIntervalForResource = max(PullRequestProbeService.probeTimeout, 8)
            self.session = URLSession(configuration: configuration)
        }
        self.now = now
    }

    func response(
        endpoint: String,
        authHeader: String?,
        sessionOverride: URLSession? = nil
    ) async -> WorkspacePullRequestHTTPResponse? {
        guard let authHeader,
              !authHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard activeRateLimitRetryDate() == nil else { return nil }

        if let inFlight = inFlightRequestByEndpoint[endpoint] {
            return await inFlight.task.value
        }

        let requestID = UUID()
        let predecessor = transportTail
        let requestSession = sessionOverride ?? session
        let task = Task<WorkspacePullRequestHTTPResponse?, Never> { [weak self] in
            _ = await predecessor?.value
            guard let self else { return nil }
            return await self.executeRequest(
                endpoint: endpoint,
                authHeader: authHeader,
                session: requestSession
            )
        }
        inFlightRequestByEndpoint[endpoint] = InFlightRequest(id: requestID, task: task)
        transportTail = Task { _ = await task.value }

        let response = await task.value
        if inFlightRequestByEndpoint[endpoint]?.id == requestID {
            inFlightRequestByEndpoint.removeValue(forKey: endpoint)
        }
        return response
    }

    func retryDate() -> Date? {
        activeRateLimitRetryDate()
    }

    private func executeRequest(
        endpoint: String,
        authHeader: String,
        session: URLSession
    ) async -> WorkspacePullRequestHTTPResponse? {
        guard activeRateLimitRetryDate() == nil,
              let url = URL(string: "https://api.github.com/\(endpoint)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cmux-workspace-pr-poller", forHTTPHeaderField: "User-Agent")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let etag = cachedResponseByEndpoint[endpoint]?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            updateRateLimit(from: httpResponse)

            if httpResponse.statusCode == 304,
               let cachedResponse = cachedResponseByEndpoint[endpoint] {
                return WorkspacePullRequestHTTPResponse(statusCode: 200, data: cachedResponse.data)
            }

            if httpResponse.statusCode == 200 {
                if let etag = httpResponse.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                    cachedResponseByEndpoint[endpoint] = CachedResponse(etag: etag, data: data)
                } else {
                    cachedResponseByEndpoint.removeValue(forKey: endpoint)
                }
            }
            return WorkspacePullRequestHTTPResponse(statusCode: httpResponse.statusCode, data: data)
        } catch {
            return nil
        }
    }

    private func updateRateLimit(from response: HTTPURLResponse) {
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        let isExhausted = remaining == "0" || response.statusCode == 403 || response.statusCode == 429
        guard isExhausted,
              let rawReset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let resetSeconds = TimeInterval(rawReset) else {
            return
        }

        // GitHub reports whole epoch seconds. Waiting through the following
        // second avoids racing the boundary and immediately receiving another
        // exhausted response.
        let resetDate = Date(timeIntervalSince1970: resetSeconds + 1)
        if resetDate > now() {
            rateLimitRetryDate = max(rateLimitRetryDate ?? .distantPast, resetDate)
        }
    }

    private func activeRateLimitRetryDate() -> Date? {
        guard let rateLimitRetryDate else { return nil }
        guard rateLimitRetryDate > now() else {
            self.rateLimitRetryDate = nil
            return nil
        }
        return rateLimitRetryDate
    }
}
