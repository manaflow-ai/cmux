public import Foundation
internal import OSLog

private let verboseDiagnosticsUploadLog = Logger(
    subsystem: "dev.cmux.ios",
    category: "verbose-diagnostics-upload"
)

/// A ``VerboseDiagnosticsUploading`` that POSTs batches to the cmux web API.
///
/// Mirrors ``HTTPAnalyticsUploader``'s request shape: `Bearer <accessToken>` +
/// `X-Stack-Refresh-Token`, posting JSON to
/// `<apiBaseURL>/api/diagnostics/ingest`. The endpoint authenticates the Stack
/// user and re-checks the server-written `cmuxVerboseDiagnostics` account flag
/// before accepting anything, so this uploader carries no authority of its
/// own. Status mapping matches the analytics uploader: `2xx` → `accepted`, a
/// `4xx` other than `408`/`429` → `drop`, everything else → `retry`. The
/// ``VerboseDiagnosticsReporter`` treats `drop` and `retry` identically (the
/// batch is discarded either way); the distinction is kept so tests and logs
/// can tell rejection from outage.
public struct HTTPVerboseDiagnosticsUploader: VerboseDiagnosticsUploading {
    private let apiBaseURL: String
    private let tokenProvider: any AnalyticsTokenProviding
    private let session: URLSession

    /// Creates an uploader.
    ///
    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL, no trailing slash (resolved
    ///     at the composition root from the same `LocalConfig.plist` /
    ///     `ApiBaseURL` override table the auth + analytics services use).
    ///   - tokenProvider: Supplies the Stack bearer/refresh tokens.
    ///   - session: The URLSession used for the POST. Inject a short-timeout
    ///     session from the composition root so a hung upload cannot pin the
    ///     reporter's consumer for long.
    public init(
        apiBaseURL: String,
        tokenProvider: any AnalyticsTokenProviding,
        session: sending URLSession = .shared
    ) {
        self.apiBaseURL = apiBaseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public func upload(_ batch: VerboseDiagnosticsBatch) async -> AnalyticsUploadResult {
        guard !batch.entries.isEmpty else { return .accepted }
        guard let url = URL(string: apiBaseURL + "/api/diagnostics/ingest") else { return .drop }
        guard let payload = try? JSONSerialization.data(
            withJSONObject: Self.wireObject(for: batch)
        ) else { return .drop }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        guard let accessToken = await tokenProvider.accessToken() else {
            // The endpoint requires auth; without a token the POST can only
            // 401. Skip the round trip.
            return .drop
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let refreshToken = await tokenProvider.refreshToken() {
            request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retry }
            return Self.result(forStatusCode: http.statusCode)
        } catch {
            if Task.isCancelled { return .drop }
            verboseDiagnosticsUploadLog.error(
                "upload transport error=\(error.localizedDescription, privacy: .private)"
            )
            return .retry
        }
    }

    static func wireObject(for batch: VerboseDiagnosticsBatch) -> [String: Any] {
        var body: [String: Any] = [
            "batch": batch.entries.map(wireObject(for:)),
            "buildStamp": batch.buildStamp,
        ]
        if let clientID = batch.clientID {
            body["clientId"] = clientID
        }
        return body
    }

    private static func wireObject(for entry: VerboseDiagnosticsEntry) -> [String: Any] {
        var object: [String: Any] = [
            "at": entry.at.ISO8601Format(timestampFormat),
            "code": entry.code,
            "name": entry.name,
            "summary": entry.summary,
        ]
        if let surface = entry.surface { object["surface"] = Int(surface) }
        if let ms = entry.ms { object["ms"] = Int(ms) }
        if let a = entry.a { object["a"] = a }
        if let b = entry.b { object["b"] = b }
        if let c = entry.c { object["c"] = c }
        return object
    }

    private static let timestampFormat = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    private static func result(forStatusCode statusCode: Int) -> AnalyticsUploadResult {
        if (200...299).contains(statusCode) { return .accepted }
        if statusCode == 408 || statusCode == 429 { return .retry }
        if (400...499).contains(statusCode) {
            verboseDiagnosticsUploadLog.error(
                "upload rejected status=\(statusCode, privacy: .public)"
            )
            return .drop
        }
        return .retry
    }
}
