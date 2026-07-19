import CryptoKit
import Foundation

private func githubAuthorizationFingerprint(for authHeader: String) -> Data {
    Data(SHA256.hash(data: Data(authHeader.utf8)))
}

/// Process-scoped transport policy for GitHub pull-request probes.
///
/// A single instance is shared by every app window. It owns the reusable
/// session, conditional-response cache, rate-limit deadline, in-flight request
/// coalescing, and a bounded transport pool. Keeping these concerns here
/// prevents per-window pollers from independently consuming the same GitHub
/// rate-limit pool.
actor GitHubPullRequestRequestCoordinator {
    private static let maximumConcurrentTransportCount = 3
    private static let maximumRateLimitIdentityCount = 32

    internal struct RequestKey: Hashable, Sendable {
        let endpoint: String
        let authorizationFingerprint: Data
    }

    private struct CachedResponse: Sendable {
        let etag: String
        let data: Data
    }

    internal struct InFlightRequest: Sendable {
        let id: UUID
        let task: Task<Void, Never>
        var waiterContinuations: [UUID: CheckedContinuation<WorkspacePullRequestHTTPResponse?, Never>]

        var waiterIDs: Set<UUID> {
            Set(waiterContinuations.keys)
        }
    }

    internal struct QueuedTransport: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let maximumCachedResponseCount: Int
    private let maximumCachedResponseBodyBytes: Int
    private var cachedResponseByRequestKey: [RequestKey: CachedResponse] = [:]
    private var cachedResponseKeysInInsertionOrder: [RequestKey] = []
    private var cachedResponseBodyByteCount = 0
    internal var inFlightRequestByRequestKey: [RequestKey: InFlightRequest] = [:]
    private var activeTransportCount = 0
    internal var queuedTransports: [QueuedTransport] = []
    private var rateLimitRetryDateByAuthorizationFingerprint: [Data: Date] = [:]
    private var rateLimitAuthorizationFingerprintsInInsertionOrder: [Data] = []

    init(
        session: URLSession? = nil,
        maximumCachedResponseCount: Int = 128,
        maximumCachedResponseBodyBytes: Int = 4 * 1024 * 1024,
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
        self.maximumCachedResponseCount = max(0, maximumCachedResponseCount)
        self.maximumCachedResponseBodyBytes = max(0, maximumCachedResponseBodyBytes)
        self.now = now
    }

    func response(
        endpoint: String,
        authHeader: String?
    ) async -> WorkspacePullRequestHTTPResponse? {
        guard let authHeader,
              !authHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let requestKey = RequestKey(
            endpoint: endpoint,
            authorizationFingerprint: githubAuthorizationFingerprint(for: authHeader)
        )
        guard activeRateLimitRetryDate(
            for: requestKey.authorizationFingerprint
        ) == nil else { return nil }
        guard !Task.isCancelled else { return nil }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            let response = await withCheckedContinuation {
                (continuation: CheckedContinuation<WorkspacePullRequestHTTPResponse?, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if var inFlight = inFlightRequestByRequestKey[requestKey] {
                    inFlight.waiterContinuations[waiterID] = continuation
                    inFlightRequestByRequestKey[requestKey] = inFlight
                    return
                }

                let requestID = UUID()
                let task = Task<Void, Never> { [weak self] in
                    guard !Task.isCancelled, let self else { return }
                    let response = await self.executeRequest(
                        requestID: requestID,
                        requestKey: requestKey,
                        authHeader: authHeader
                    )
                    await self.completeRequest(
                        response,
                        requestID: requestID,
                        requestKey: requestKey
                    )
                }
                inFlightRequestByRequestKey[requestKey] = InFlightRequest(
                    id: requestID,
                    task: task,
                    waiterContinuations: [waiterID: continuation]
                )
            }
            return Task.isCancelled ? nil : response
        } onCancel: { [weak self] in
            guard let self else { return }
            Task {
                await self.cancelWaiter(
                    waiterID,
                    requestKey: requestKey
                )
            }
        }
    }

    func retryDate(authHeader: String) -> Date? {
        guard !authHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return activeRateLimitRetryDate(
            for: githubAuthorizationFingerprint(for: authHeader)
        )
    }

    private func executeRequest(
        requestID: UUID,
        requestKey: RequestKey,
        authHeader: String
    ) async -> WorkspacePullRequestHTTPResponse? {
        guard await acquireTransportPermit(requestID: requestID) else { return nil }
        defer { releaseTransportPermit() }
        guard !Task.isCancelled else { return nil }
        guard activeRateLimitRetryDate(
            for: requestKey.authorizationFingerprint
        ) == nil,
              let url = URL(string: "https://api.github.com/\(requestKey.endpoint)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("cmux-workspace-pr-poller", forHTTPHeaderField: "User-Agent")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        let cachedResponse = cachedResponseByRequestKey[requestKey]
        if let cachedResponse {
            request.setValue(cachedResponse.etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            updateRateLimit(
                from: httpResponse,
                authorizationFingerprint: requestKey.authorizationFingerprint
            )

            if httpResponse.statusCode == 304, let cachedResponse {
                return WorkspacePullRequestHTTPResponse(statusCode: 200, data: cachedResponse.data)
            }

            if httpResponse.statusCode == 200 {
                if let etag = httpResponse.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                    storeCachedResponse(CachedResponse(etag: etag, data: data), for: requestKey)
                } else {
                    removeCachedResponse(for: requestKey)
                }
            }
            return WorkspacePullRequestHTTPResponse(statusCode: httpResponse.statusCode, data: data)
        } catch {
            return nil
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        requestKey: RequestKey
    ) {
        guard var inFlight = inFlightRequestByRequestKey[requestKey],
              let continuation = inFlight.waiterContinuations.removeValue(forKey: waiterID) else {
            return
        }
        if inFlight.waiterContinuations.isEmpty {
            inFlightRequestByRequestKey.removeValue(forKey: requestKey)
            inFlight.task.cancel()
        } else {
            inFlightRequestByRequestKey[requestKey] = inFlight
        }
        continuation.resume(returning: nil)
    }

    private func completeRequest(
        _ response: WorkspacePullRequestHTTPResponse?,
        requestID: UUID,
        requestKey: RequestKey
    ) {
        guard let inFlight = inFlightRequestByRequestKey[requestKey],
              inFlight.id == requestID else { return }
        inFlightRequestByRequestKey.removeValue(forKey: requestKey)
        for continuation in inFlight.waiterContinuations.values {
            continuation.resume(returning: response)
        }
    }

    private func acquireTransportPermit(requestID: UUID) async -> Bool {
        guard !Task.isCancelled else { return false }
        if activeTransportCount < Self.maximumConcurrentTransportCount {
            activeTransportCount += 1
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                queuedTransports.append(QueuedTransport(id: requestID, continuation: continuation))
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            Task { await self.cancelQueuedTransport(requestID: requestID) }
        }
    }

    private func cancelQueuedTransport(requestID: UUID) {
        guard let index = queuedTransports.firstIndex(where: { $0.id == requestID }) else { return }
        queuedTransports.remove(at: index).continuation.resume(returning: false)
    }

    private func releaseTransportPermit() {
        guard !queuedTransports.isEmpty else {
            activeTransportCount -= 1
            return
        }
        queuedTransports.removeFirst().continuation.resume(returning: true)
    }

    private func updateRateLimit(
        from response: HTTPURLResponse,
        authorizationFingerprint: Data
    ) {
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
           let rawReset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let resetSeconds = TimeInterval(rawReset) {
            // GitHub reports whole epoch seconds. Waiting through the following
            // second avoids racing the boundary and immediately receiving another
            // exhausted response.
            extendRateLimitRetryDate(
                to: Date(timeIntervalSince1970: resetSeconds + 1),
                authorizationFingerprint: authorizationFingerprint
            )
        }

        if response.statusCode == 403 || response.statusCode == 429,
           let rawRetryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let retryAfter = TimeInterval(rawRetryAfter),
           retryAfter > 0 {
            extendRateLimitRetryDate(
                to: now().addingTimeInterval(retryAfter),
                authorizationFingerprint: authorizationFingerprint
            )
        }
    }

    private func extendRateLimitRetryDate(
        to retryDate: Date,
        authorizationFingerprint: Data
    ) {
        guard retryDate > now() else { return }
        removeExpiredRateLimitRetryDates()
        rateLimitAuthorizationFingerprintsInInsertionOrder.removeAll { $0 == authorizationFingerprint }
        rateLimitAuthorizationFingerprintsInInsertionOrder.append(authorizationFingerprint)
        rateLimitRetryDateByAuthorizationFingerprint[authorizationFingerprint] = max(
            rateLimitRetryDateByAuthorizationFingerprint[authorizationFingerprint] ?? .distantPast,
            retryDate
        )
        while rateLimitRetryDateByAuthorizationFingerprint.count > Self.maximumRateLimitIdentityCount {
            guard let oldestFingerprint = rateLimitAuthorizationFingerprintsInInsertionOrder.first else { break }
            rateLimitAuthorizationFingerprintsInInsertionOrder.removeFirst()
            rateLimitRetryDateByAuthorizationFingerprint.removeValue(forKey: oldestFingerprint)
        }
    }

    private func storeCachedResponse(_ response: CachedResponse, for requestKey: RequestKey) {
        removeCachedResponse(for: requestKey)
        guard maximumCachedResponseCount > 0,
              maximumCachedResponseBodyBytes > 0,
              response.data.count <= maximumCachedResponseBodyBytes else {
            return
        }

        cachedResponseByRequestKey[requestKey] = response
        cachedResponseKeysInInsertionOrder.append(requestKey)
        cachedResponseBodyByteCount += response.data.count

        while cachedResponseByRequestKey.count > maximumCachedResponseCount
            || cachedResponseBodyByteCount > maximumCachedResponseBodyBytes {
            guard let oldestRequestKey = cachedResponseKeysInInsertionOrder.first else { break }
            removeCachedResponse(for: oldestRequestKey)
        }
    }

    private func removeCachedResponse(for requestKey: RequestKey) {
        if let removedResponse = cachedResponseByRequestKey.removeValue(forKey: requestKey) {
            cachedResponseBodyByteCount -= removedResponse.data.count
        }
        cachedResponseKeysInInsertionOrder.removeAll { $0 == requestKey }
    }

    private func activeRateLimitRetryDate(for authorizationFingerprint: Data) -> Date? {
        removeExpiredRateLimitRetryDates()
        return rateLimitRetryDateByAuthorizationFingerprint[authorizationFingerprint]
    }

    private func removeExpiredRateLimitRetryDates() {
        let currentDate = now()
        rateLimitRetryDateByAuthorizationFingerprint = rateLimitRetryDateByAuthorizationFingerprint.filter {
            $0.value > currentDate
        }
        rateLimitAuthorizationFingerprintsInInsertionOrder.removeAll {
            rateLimitRetryDateByAuthorizationFingerprint[$0] == nil
        }
    }
}
