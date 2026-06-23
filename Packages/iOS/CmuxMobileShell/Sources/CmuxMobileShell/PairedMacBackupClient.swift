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

    /// Build the paired-Mac backup endpoint from a service base URL. The base
    /// may include or omit a trailing slash, and may include a deployment base
    /// path, but must be an HTTP(S) URL.
    static func endpointURL(serviceBaseURL: String) -> URL? {
        guard var components = URLComponents(string: serviceBaseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "http", "https":
            break
        default:
            return nil
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + Self.path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Upload backup mutations to the presence worker.
    @discardableResult
    public func upload(ops: [PairedMacBackupOp]) async -> Bool {
        let teamID = await teamIDProvider()
        return await upload(ops: ops, teamID: teamID)
    }

    /// Upload backup mutations to the presence worker for an already-captured team.
    @discardableResult
    public func upload(ops: [PairedMacBackupOp], teamID: String?) async -> Bool {
        await upload(ops: ops, teamID: teamID, expectedUserID: nil)
    }

    /// Upload backup mutations only if auth still belongs to the captured account.
    @discardableResult
    public func upload(ops: [PairedMacBackupOp], teamID: String?, expectedUserID: String?) async -> Bool {
        guard !ops.isEmpty else { return true }
        let body = PairedMacBackupRequestBody(ops: ops.map(PairedMacBackupOpWire.init(op:)))
        guard let data = try? JSONEncoder().encode(body),
              let request = await makeRequest(
                method: "POST",
                body: data,
                teamID: teamID,
                expectedUserID: expectedUserID
              ) else {
            return false
        }
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                pairedMacBackupLog.warning("paired-mac backup upload failed: HTTP \(http.statusCode)")
                return false
            }
            return true
        } catch {
            pairedMacBackupLog.warning("paired-mac backup upload error: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Fetch every backed-up paired Mac for the current user/team scope.
    public func fetchAll() async -> [PairedMacBackupRecord]? {
        await fetchSnapshot()?.records
    }

    /// Fetch live records and delete tombstones for the current user/team scope.
    public func fetchSnapshot() async -> PairedMacBackupSnapshot? {
        let teamID = await teamIDProvider()
        return await fetchSnapshot(teamID: teamID)
    }

    /// Fetch every backed-up paired Mac for an already-captured user/team scope.
    public func fetchAll(teamID: String?) async -> [PairedMacBackupRecord]? {
        await fetchSnapshot(teamID: teamID)?.records
    }

    /// Fetch live records and delete tombstones for an already-captured user/team scope.
    public func fetchSnapshot(teamID: String?) async -> PairedMacBackupSnapshot? {
        await fetchSnapshot(teamID: teamID, expectedUserID: nil)
    }

    /// Fetch live records and tombstones only if auth still belongs to the captured account.
    public func fetchSnapshot(teamID: String?, expectedUserID: String?) async -> PairedMacBackupSnapshot? {
        guard let request = await makeRequest(
            method: "GET",
            body: nil,
            teamID: teamID,
            expectedUserID: expectedUserID
        ) else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                pairedMacBackupLog.warning("paired-mac backup fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            // A 2xx with an undecodable body is a real failure, not "no hosts".
            return (try? JSONDecoder().decode(PairedMacBackupListResponse.self, from: data))?.snapshot
        } catch {
            pairedMacBackupLog.warning("paired-mac backup fetch error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func makeRequest(
        method: String,
        body: Data?,
        teamID: String?,
        expectedUserID: String?
    ) async -> URLRequest? {
        guard let accessToken = await tokenSource.accessToken(expectedUserID: expectedUserID),
              let url = Self.endpointURL(serviceBaseURL: serviceBaseURL) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID, !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}
