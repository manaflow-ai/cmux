public import CmuxConnectivityTelemetry
public import Foundation

/// Sends connectivity stat batches to the Cloud service (`POST /v1/telemetry/connectivity`),
/// as the signed-in account (the account's access token, refreshed once after a 401). The
/// service decides the tier from that account and logs one line per stat.
public struct ConnectivityStatsHTTP: Sendable {
    public let base: URL
    let accessToken: @Sendable (_ forceRefresh: Bool) async throws -> String
    let session: URLSession

    public init(base: URL, session: URLSession = .shared,
                accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.base = base
        self.session = session
        self.accessToken = accessToken
    }

    /// A 2xx is sent. Offline, a 5xx, a rate limit or a token that cannot be refreshed waits for
    /// the next flush. Any other answer (a 4xx, a deployment without the route) drops the batch.
    public func post(_ body: Data) async -> ConnectivityStats.UploadResult {
        var request = URLRequest(url: base.appending(path: "v1/telemetry/connectivity"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        for forceRefresh in [false, true] {
            guard let token = try? await accessToken(forceRefresh) else { return .retryLater }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            guard let (_, response) = try? await session.data(for: request) else { return .retryLater }
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300: return .sent
            case 401 where !forceRefresh: continue
            case 401, 408, 429, 500...: return .retryLater
            default: return .discard
            }
        }
        return .retryLater
    }
}
