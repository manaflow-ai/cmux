public import Foundation
internal import CmuxMobilePairedMac
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
    private let clientScopeProvider: @Sendable () async -> String?
    private let legacyClientScopeProvider: (@Sendable () async -> String?)?
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let migrationDefaults: UserDefaults

    /// Create a backup client for one presence service base URL and token source.
    public init(
        serviceBaseURL: String,
        tokenSource: PresenceTokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        clientScopeProvider: @escaping @Sendable () async -> String? = { nil },
        legacyClientScopeProvider: (@Sendable () async -> String?)? = nil,
        session: sending URLSession = .shared,
        requestTimeout: TimeInterval = 5,
        migrationDefaults: UserDefaults = .standard
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.clientScopeProvider = clientScopeProvider
        self.legacyClientScopeProvider = legacyClientScopeProvider
        self.session = session
        self.requestTimeout = requestTimeout
        self.migrationDefaults = migrationDefaults
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
    public func upload(
        ops: [PairedMacBackupOp],
        teamID: String?,
        expectedUserID: String?
    ) async -> Bool {
        await upload(
            ops: ops,
            teamID: teamID,
            expectedUserID: expectedUserID,
            routeDisclosureDate: Date()
        )
    }

    func upload(
        ops: [PairedMacBackupOp],
        teamID: String?,
        expectedUserID: String?,
        routeDisclosureDate: Date
    ) async -> Bool {
        guard !ops.isEmpty else { return true }
        let body = PairedMacBackupRequestBody(ops: ops.map {
            PairedMacBackupOpWire(
                op: $0,
                routeDisclosureDate: routeDisclosureDate
            )
        })
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
        guard let primary = await fetchSnapshot(
            teamID: teamID,
            expectedUserID: expectedUserID,
            scope: .current
        ) else { return nil }
        guard let legacyClientScopeProvider else {
            return primary
        }
        let legacyScope = await legacyClientScopeProvider()
        let currentScope = await clientScope()
        guard legacyScope != currentScope else {
            return primary
        }
        let migrationKey = pairedMacBackupMigrationKey(
            currentScope: currentScope,
            legacyScope: legacyScope,
            teamID: teamID,
            expectedUserID: expectedUserID
        )
        guard !migrationDefaults.bool(forKey: migrationKey),
              let legacy = await fetchSnapshot(
                teamID: teamID,
                expectedUserID: expectedUserID,
                scope: .explicit(legacyScope)
              ) else {
            return primary
        }
        let currentIDs = Set(primary.records.map(pairedMacBackupPairingID))
        let currentTombstones = Set(primary.deletedMacDeviceIDs)
        let legacyTombstones = Set(legacy.deletedMacDeviceIDs)
        let missingLegacyTombstones = legacyTombstones
            .subtracting(currentTombstones)
        let missingLegacy = legacy.records.filter {
            let pairingID = pairedMacBackupPairingID($0)
            return !currentIDs.contains(pairingID)
                && !currentTombstones.contains(pairingID)
                && !legacyTombstones.contains(pairingID)
        }
        let migrationOps =
            missingLegacyTombstones.sorted().map(
                pairedMacBackupDeleteOp
            )
            + missingLegacy.map { .upsert($0) }
        if migrationOps.isEmpty {
            migrationDefaults.set(true, forKey: migrationKey)
            return primary
        }
        guard await upload(
            ops: migrationOps,
            teamID: teamID,
            expectedUserID: expectedUserID
        ),
        let refreshed = await fetchSnapshot(
            teamID: teamID,
            expectedUserID: expectedUserID,
            scope: .current
        ) else {
            return primary
        }
        let refreshedIDs = Set(refreshed.records.map(
            pairedMacBackupPairingID
        ))
        let refreshedTombstones = Set(refreshed.deletedMacDeviceIDs)
        if missingLegacy.allSatisfy({
            refreshedIDs.contains(pairedMacBackupPairingID($0))
        }),
        missingLegacyTombstones.isSubset(of: refreshedTombstones) {
            migrationDefaults.set(true, forKey: migrationKey)
        }
        return refreshed
    }

    private func fetchSnapshot(
        teamID: String?,
        expectedUserID: String?,
        scope: PairedMacBackupClientScopeSelection
    ) async -> PairedMacBackupSnapshot? {
        guard let request = await makeRequest(
            method: "GET",
            body: nil,
            teamID: teamID,
            expectedUserID: expectedUserID,
            scope: scope
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

    public func clientScope() async -> String? {
        let trimmed = await clientScopeProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeRequest(
        method: String,
        body: Data?,
        teamID: String?,
        expectedUserID: String?,
        scope: PairedMacBackupClientScopeSelection = .current
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
        let resolvedScope: String?
        switch scope {
        case .current:
            resolvedScope = await clientScope()
        case .explicit(let explicit):
            let trimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            resolvedScope = trimmed.isEmpty ? nil : trimmed
        }
        if let resolvedScope {
            request.setValue(resolvedScope, forHTTPHeaderField: "X-Cmux-Client-Scope")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}

private func pairedMacBackupPairingID(
    _ record: PairedMacBackupRecord
) -> String {
    MobilePairedMac.pairingID(
        macDeviceID: record.macDeviceID,
        instanceTag: record.instanceTag
    )
}

private func pairedMacBackupDeleteOp(
    _ pairingID: String
) -> PairedMacBackupOp {
    let identity = MobilePairedMac.pairingIdentity(from: pairingID)
    if let instanceTag = identity.instanceTag {
        return .deleteInstance(
            macDeviceID: identity.macDeviceID,
            instanceTag: instanceTag
        )
    }
    return .delete(macDeviceID: identity.macDeviceID)
}

private func pairedMacBackupMigrationKey(
    currentScope: String?,
    legacyScope: String?,
    teamID: String?,
    expectedUserID: String?
) -> String {
    let identity = [
        currentScope ?? "<unscoped>",
        legacyScope ?? "<unscoped>",
        teamID ?? "<personal>",
        expectedUserID ?? "<current-user>",
    ].joined(separator: "\u{0}")
    let encoded = Data(identity.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "cmux.pairedMacBackup.legacyMigration.v1.\(encoded)"
}
