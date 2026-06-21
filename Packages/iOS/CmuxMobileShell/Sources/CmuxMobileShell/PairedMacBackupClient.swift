public import CMUXMobileCore
public import Foundation
import os

private let pairedMacBackupLog = Logger(subsystem: "com.cmuxterm.app", category: "PairedMacBackup")

/// One saved-host backup record on the wire. Mirrors the iOS `MobilePairedMac`
/// row and the server's `PairedMacBackupRecord` so a restore is lossless.
/// Timestamps are epoch milliseconds (the presence/sync wire convention; the
/// local store uses seconds, and the boundary is converted in
/// ``BackingUpPairedMacStore`` / ``PairedMacRestore``).
public struct PairedMacBackupRecord: Codable, Sendable, Equatable {
    public var macDeviceID: String
    public var displayName: String?
    public var routes: [CmxAttachRoute]
    public var createdAt: Double
    public var lastSeenAt: Double
    public var isActive: Bool
    /// User customizations, synced per user. Optional + decoded leniently so an
    /// older client/record without them round-trips to `nil`.
    public var customName: String?
    public var customColor: String?
    public var customIcon: String?

    public init(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        createdAt: Double,
        lastSeenAt: Double,
        isActive: Bool,
        customName: String? = nil,
        customColor: String? = nil,
        customIcon: String? = nil
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.routes = routes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
        self.customName = customName
        self.customColor = customColor
        self.customIcon = customIcon
    }

    enum CodingKeys: String, CodingKey {
        case macDeviceID, displayName, routes, createdAt, lastSeenAt, isActive
        case customName, customColor, customIcon
    }

    /// Custom encode so an iOS upload is AUTHORITATIVE over customizations: the
    /// three custom keys are ALWAYS emitted (as `null` when cleared/Auto), never
    /// omitted. The server preserves a record's customizations only when an upload
    /// OMITS these keys — which is exactly what the Mac's route-publish does (it
    /// never knows the user's customizations). So "iOS reset a field to Auto" (key
    /// present, null) stays distinguishable from "a Mac refreshed its route" (key
    /// absent), and a Mac heartbeat can no longer clobber the user's saved
    /// name/color/icon. (Synthesized encoding would use `encodeIfPresent` and drop
    /// nil keys, making an iOS clear indistinguishable from a Mac publish.)
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(macDeviceID, forKey: .macDeviceID)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try c.encode(routes, forKey: .routes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastSeenAt, forKey: .lastSeenAt)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(customName, forKey: .customName)
        try c.encode(customColor, forKey: .customColor)
        try c.encode(customIcon, forKey: .customIcon)
    }
}

/// A single backup mutation: upsert a record, or tombstone one by id.
public enum PairedMacBackupOp: Sendable, Equatable {
    case upsert(PairedMacBackupRecord)
    case delete(macDeviceID: String)
}

/// The backup transport seam, so ``BackingUpPairedMacStore`` and
/// ``PairedMacRestore`` can be tested against an in-memory double.
public protocol PairedMacBackingUp: Sendable {
    /// Push backup mutations. Best-effort: implementations never throw; a failed
    /// upload is logged and dropped (the local store stays authoritative, and a
    /// later upsert or the next sign-in reconcile re-pushes).
    func upload(ops: [PairedMacBackupOp]) async
    /// Fetch the caller's full backed-up list. Returns `nil` on a transport/auth
    /// failure (so the caller can retry later) and `[]` only when the fetch
    /// succeeded and the user genuinely has no backed-up hosts.
    func fetchAll() async -> [PairedMacBackupRecord]?
}

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

    public func upload(ops: [PairedMacBackupOp]) async {
        guard !ops.isEmpty else { return }
        let body = BackupRequestBody(ops: ops.map(OpWire.init(op:)))
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

    public func fetchAll() async -> [PairedMacBackupRecord]? {
        guard let request = await makeRequest(method: "GET", body: nil) else { return nil }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                pairedMacBackupLog.warning("paired-mac backup fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            // A 2xx with an undecodable body is a real failure, not "no hosts".
            return (try? JSONDecoder().decode(ListResponse.self, from: data))?.records
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

    // MARK: - Wire shapes

    private struct ListResponse: Decodable {
        let records: [PairedMacBackupRecord]
    }

    private struct BackupRequestBody: Encodable {
        let ops: [OpWire]
    }

    /// `{ macDeviceID, deleted?, record? }` matching the server's parse.
    private struct OpWire: Encodable {
        let macDeviceID: String
        let deleted: Bool?
        let record: PairedMacBackupRecord?

        init(op: PairedMacBackupOp) {
            switch op {
            case .upsert(let record):
                self.macDeviceID = record.macDeviceID
                self.deleted = nil
                self.record = record
            case .delete(let macDeviceID):
                self.macDeviceID = macDeviceID
                self.deleted = true
                self.record = nil
            }
        }
    }
}
