public import Foundation
internal import OSLog

private let networkOutcomeUploadLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "network-observability-upload"
)

/// Posts operational network outcomes to cmux's authenticated Axiom bridge.
///
/// The destination is the first-party `/api/observability/mobile-network`
/// endpoint. Axiom credentials stay on the server, while the mobile request
/// uses the same Stack bearer and refresh-token contract as other cmux APIs.
public struct HTTPMobileNetworkOutcomeUploader: AnalyticsUploading {
    private let apiBaseURL: String
    private let tokenProvider: any AnalyticsTokenProviding
    private let session: URLSession
    private let taskRegistry = AnalyticsUploadTaskRegistry()

    /// Creates an operational network-outcome uploader.
    ///
    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL with no trailing slash.
    ///   - tokenProvider: Supplies the current Stack credentials.
    ///   - session: The short-timeout session used for best-effort uploads.
    public init(
        apiBaseURL: String,
        tokenProvider: any AnalyticsTokenProviding,
        session: sending URLSession? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.tokenProvider = tokenProvider
        self.session = session ?? Self.shortTimeoutSession()
    }

    /// Uploads one batch to the Axiom-backed observability endpoint.
    public func upload(_ events: [AnalyticsEvent]) async -> AnalyticsUploadResult {
        guard !events.isEmpty else { return .accepted }
        let batch: [[String: any Sendable]] = events.map { event in
            var properties: [String: any Sendable] = [:]
            for (key, value) in event.properties {
                properties[key] = value.jsonObject
            }
            return [
                "event": event.name,
                "properties": properties,
                "timestamp": event.timestamp.ISO8601Format(.iso8601.dateTimeSeparator(.standard)),
            ]
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["batch": batch]) else {
            return .drop
        }
        return await post(payload)
    }

    /// Operational telemetry has no identity mutation. The server attributes
    /// accepted batches to the authenticated Stack user.
    public func identify(
        userID _: String?,
        anonymousID _: String?,
        properties _: [String: any Sendable]
    ) async -> AnalyticsUploadResult {
        .accepted
    }

    /// Cancels in-flight uploads immediately when telemetry consent is revoked.
    public func setUploadsEnabled(_ isEnabled: Bool) {
        taskRegistry.setEnabled(isEnabled)
    }

    private func post(_ payload: Data) async -> AnalyticsUploadResult {
        guard let url = URL(string: apiBaseURL + "/api/observability/mobile-network") else {
            return .drop
        }
        let id = UUID()
        let startGate = AnalyticsUploadStartGate()
        let task = Task<AnalyticsUploadResult, Never> { [self] in
            await startGate.wait()
            guard !Task.isCancelled else { return .drop }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            if let accessToken = await tokenProvider.accessToken() {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            guard !Task.isCancelled else { return .drop }
            if let refreshToken = await tokenProvider.refreshToken() {
                request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
            }
            guard !Task.isCancelled else { return .drop }
            return await perform(request)
        }
        guard taskRegistry.register(task, id: id) else {
            task.cancel()
            startGate.open()
            return .drop
        }
        startGate.open()
        defer { taskRegistry.remove(id: id) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func perform(_ request: URLRequest) async -> AnalyticsUploadResult {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retry }
            return Self.result(forStatusCode: http.statusCode)
        } catch {
            if Task.isCancelled { return .drop }
            networkOutcomeUploadLog.error(
                "network outcome transport error=\(error.localizedDescription, privacy: .private)"
            )
            return .retry
        }
    }

    private static func shortTimeoutSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    static func result(forStatusCode statusCode: Int) -> AnalyticsUploadResult {
        if (200...299).contains(statusCode) { return .accepted }
        // Missing auth is normally transient during launch/sign-in. Keep the
        // bounded batch so it can ship once the token provider recovers.
        if statusCode == 401 || statusCode == 408 || statusCode == 429 {
            return .retry
        }
        if (400...499).contains(statusCode) {
            networkOutcomeUploadLog.error(
                "network outcomes dropped status=\(statusCode, privacy: .public)"
            )
            return .drop
        }
        return .retry
    }
}
