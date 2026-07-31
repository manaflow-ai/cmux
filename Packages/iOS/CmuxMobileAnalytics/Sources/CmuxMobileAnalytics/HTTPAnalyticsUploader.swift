public import Foundation
internal import OSLog

private let analyticsUploadLog = Logger(subsystem: "dev.cmux.ios", category: "analytics-upload")

/// An ``AnalyticsUploading`` that POSTs batches to the cmux web analytics proxy.
///
/// Mirrors ``PushRegistrationService``'s request shape: `Bearer <accessToken>` +
/// `X-Stack-Refresh-Token`, posting JSON to `<apiBaseURL>/api/analytics/events`.
/// The proxy validates the event-name allowlist and forwards the batch to
/// PostHog server-to-server, so no PostHog key ships in the app. Network work
/// happens entirely inside this `Sendable` value's `async` methods, called only
/// from the emitter actor's flush task — never on a UI or input path.
///
/// Status-code mapping: `2xx` → ``AnalyticsUploadResult/accepted``; a `4xx`
/// other than `408`/`429` → ``AnalyticsUploadResult/drop`` (the client batch is
/// malformed or unauthorized, retrying won't help); everything else (`5xx`,
/// `408`, `429`, transport error) → ``AnalyticsUploadResult/retry``.
public struct HTTPAnalyticsUploader: AnalyticsUploading {
    private let apiBaseURL: String
    private let tokenProvider: any AnalyticsTokenProviding
    private let session: URLSession
    private let taskRegistry = AnalyticsUploadTaskRegistry()

    /// Creates an uploader.
    ///
    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL, no trailing slash (resolved at
    ///     the composition root from the same `LocalConfig.plist`/`ApiBaseURL`
    ///     override table the auth + push services use).
    ///   - tokenProvider: Supplies the Stack bearer/refresh tokens.
    ///   - session: The URLSession used for the POST. Defaults to `.shared`.
    public init(
        apiBaseURL: String,
        tokenProvider: any AnalyticsTokenProviding,
        session: sending URLSession = .shared
    ) {
        self.apiBaseURL = apiBaseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    /// Uploads one event batch through the authenticated cmux analytics proxy.
    public func upload(_ events: [AnalyticsEvent]) async -> AnalyticsUploadResult {
        guard !events.isEmpty else { return .accepted }
        let batch: [String: any Sendable] = ["batch": events.map(\.wireObject)]
        return await post(path: "/api/analytics/events", body: batch, label: "capture")
    }

    /// Sends an identity transition through the authenticated cmux analytics proxy.
    public func identify(
        userID: String?,
        anonymousID: String?,
        properties: [String: any Sendable]
    ) async -> AnalyticsUploadResult {
        var body: [String: any Sendable] = [
            "event": "$identify",
            "distinct_id": userID ?? anonymousID ?? "anonymous",
        ]
        var props = properties
        if let anonymousID { props["$anon_distinct_id"] = anonymousID }
        body["properties"] = props
        return await post(path: "/api/analytics/events", body: ["batch": [body]], label: "identify")
    }

    /// Cancels registered requests when uploads are disabled and gates new ones.
    public func setUploadsEnabled(_ isEnabled: Bool) {
        taskRegistry.setEnabled(isEnabled)
    }

    private func post(
        path: String,
        body: [String: any Sendable],
        label: String
    ) async -> AnalyticsUploadResult {
        guard let url = URL(string: apiBaseURL + path) else { return .drop }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return .drop }

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
            return await perform(request: request, label: label)
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

    private func perform(request: URLRequest, label: String) async -> AnalyticsUploadResult {
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retry }
            return Self.result(forStatusCode: http.statusCode, label: label)
        } catch {
            if Task.isCancelled { return .drop }
            analyticsUploadLog.error("\(label, privacy: .public) transport error=\(error.localizedDescription, privacy: .private)")
            return .retry
        }
    }

    private static func result(forStatusCode statusCode: Int, label: String) -> AnalyticsUploadResult {
        if (200...299).contains(statusCode) { return .accepted }
        if statusCode == 408 || statusCode == 429 { return .retry }
        if (400...499).contains(statusCode) {
            analyticsUploadLog.error("\(label, privacy: .public) dropped status=\(statusCode, privacy: .public)")
            return .drop
        }
        return .retry
    }
}
