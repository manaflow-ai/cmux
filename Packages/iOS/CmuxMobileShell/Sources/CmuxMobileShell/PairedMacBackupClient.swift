public import CMUXMobileCore
public import Foundation
import os

private let pairedMacBackupLog = Logger(subsystem: "com.cmuxterm.app", category: "PairedMacBackup")

/// HTTP client for the per-user paired-Mac backup on the presence worker
/// (`/v1/sync/paired-macs`). Auth mirrors ``PresenceClient`` /
/// ``DeviceRegistryService``: `Authorization: Bearer <access>` plus optional
/// `X-Cmux-Team-Id`, with tokens supplied through ``PresenceTokenSource``.
public actor PairedMacBackupClient: PairedMacBackingUp {
    private let serviceBaseURL: String
    private let tokenSource: PresenceTokenSource
    private let teamIDProvider: @Sendable () async -> String?
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// Create a backup client for one presence service base URL and token source.
    public init(
        serviceBaseURL: String,
        tokenSource: PresenceTokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        session: sending URLSession = .shared,
        requestTimeout: TimeInterval = 5
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.session = session
        self.requestTimeout = requestTimeout
    }

    private static let path = "/v1/sync/paired-macs"

    /// Upload backup mutations to the presence worker.
    public func upload(ops: [PairedMacBackupOp]) async {
        guard !ops.isEmpty else { return }
        let body = PairedMacBackupRequestBody(ops: ops.map(PairedMacBackupOpWire.init(op:)))
        guard let data = try? JSONEncoder().encode(body),
              let request = await makeRequest(method: "POST", body: data) else {
            return
        }
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                pairedMacBackupLog.warning("paired-mac backup upload failed: HTTP \(http.statusCode)")
            }
        } catch {
            pairedMacBackupLog.warning("paired-mac backup upload error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Fetch every backed-up paired Mac for the current user/team scope.
    public func fetchAll() async -> [PairedMacBackupRecord]? {
        guard let request = await makeRequest(method: "GET", body: nil) else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                pairedMacBackupLog.warning("paired-mac backup fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            // A 2xx with an undecodable body is a real failure, not "no hosts".
            return (try? JSONDecoder().decode(PairedMacBackupListResponse.self, from: data))?.records
        } catch {
            pairedMacBackupLog.warning("paired-mac backup fetch error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func makeRequest(method: String, body: Data?) async -> URLRequest? {
        guard let accessToken = await tokenSource.accessToken(),
              let url = URL(string: serviceBaseURL + Self.path) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID = await teamIDProvider(), !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}
