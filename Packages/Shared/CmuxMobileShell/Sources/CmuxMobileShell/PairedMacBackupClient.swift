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
    private let migrationClock: @Sendable () -> Date

    /// Create a backup client for one presence service base URL and token source.
    public init(
        serviceBaseURL: String,
        tokenSource: PresenceTokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        clientScopeProvider: @escaping @Sendable () async -> String? = { nil },
        legacyClientScopeProvider: (@Sendable () async -> String?)? = nil,
        session: sending URLSession = .shared,
        requestTimeout: TimeInterval = 5,
        migrationDefaults: UserDefaults = .standard,
        migrationClock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.clientScopeProvider = clientScopeProvider
        self.legacyClientScopeProvider = legacyClientScopeProvider
        self.session = session
        self.requestTimeout = requestTimeout
        self.migrationDefaults = migrationDefaults
        self.migrationClock = migrationClock
    }

    private static let path = "/v1/sync/paired-macs"
    private static let maximumMigrationUploadOperations = 200
    // A fetch performs at most one conditional write. If more legacy state
    // remains, the next fetch resumes from the current snapshot.
    private static let maximumMigrationOperationsPerFetch =
        maximumMigrationUploadOperations
    // Legacy clients can continue writing the old collection after this client
    // finishes its bounded migration. Recheck periodically so the normal fetch
    // path stays cheap while late legacy writes remain eventually visible.
    private static let legacyMigrationRecheckInterval: TimeInterval = 60

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
        routeDisclosureDate: Date,
        expectedRevision: Int? = nil
    ) async -> Bool {
        await uploadReportingResolvedTeam(
            ops: ops,
            teamID: teamID,
            expectedUserID: expectedUserID,
            routeDisclosureDate: routeDisclosureDate,
            expectedRevision: expectedRevision
        ).succeeded
    }

    /// The presence worker echoes the verified team it stored the ops under.
    private struct UploadResponseBody: Decodable {
        let teamId: String?
    }

    /// Upload backup mutations and report the server-verified team they were
    /// stored under (`nil` on failure or when the worker predates the echo).
    public func uploadReportingResolvedTeam(
        ops: [PairedMacBackupOp],
        teamID: String?,
        expectedUserID: String?
    ) async -> PairedMacBackupUploadOutcome {
        await uploadReportingResolvedTeam(
            ops: ops,
            teamID: teamID,
            expectedUserID: expectedUserID,
            routeDisclosureDate: Date()
        )
    }

    func uploadReportingResolvedTeam(
        ops: [PairedMacBackupOp],
        teamID: String?,
        expectedUserID: String?,
        routeDisclosureDate: Date,
        expectedRevision: Int? = nil
    ) async -> PairedMacBackupUploadOutcome {
        guard !ops.isEmpty else {
            return PairedMacBackupUploadOutcome(succeeded: true, resolvedTeamID: nil)
        }
        let body = PairedMacBackupRequestBody(
            ops: ops.map {
                PairedMacBackupOpWire(
                    op: $0,
                    routeDisclosureDate: routeDisclosureDate
                )
            },
            expectedRevision: expectedRevision
        )
        guard let data = try? JSONEncoder().encode(body),
              let request = await makeRequest(
                method: "POST",
                body: data,
                teamID: teamID,
                expectedUserID: expectedUserID
              ) else {
            return PairedMacBackupUploadOutcome(succeeded: false, resolvedTeamID: nil)
        }
        do {
            let (responseData, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                pairedMacBackupLog.warning("paired-mac backup upload failed: HTTP \(http.statusCode)")
                return PairedMacBackupUploadOutcome(succeeded: false, resolvedTeamID: nil)
            }
            let echoedTeamID = (try? JSONDecoder().decode(UploadResponseBody.self, from: responseData))?
                .teamId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PairedMacBackupUploadOutcome(
                succeeded: true,
                resolvedTeamID: (echoedTeamID?.isEmpty ?? true) ? nil : echoedTeamID
            )
        } catch {
            pairedMacBackupLog.warning("paired-mac backup upload error: \(String(describing: error), privacy: .public)")
            return PairedMacBackupUploadOutcome(succeeded: false, resolvedTeamID: nil)
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
        // Capture the account once so every read, write, and reconciliation
        // request belongs to the same auth generation.
        let capturedUserID: String?
        if let expectedUserID {
            capturedUserID = expectedUserID
        } else {
            capturedUserID = await tokenSource.currentUserID()
        }
        guard let primaryResponse = await fetchSnapshotResponse(
            teamID: teamID,
            expectedUserID: capturedUserID,
            scope: .current
        ) else { return nil }
        let primary = primaryResponse.snapshot
        guard let legacyClientScopeProvider else {
            return primary
        }
        let legacyScope = await legacyClientScopeProvider()
        let currentScope = await clientScope()
        guard legacyScope != currentScope else {
            return primary
        }
        let requestedTeamID = teamID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let migrationTeamID = primary.resolvedTeamID
            ?? ((requestedTeamID?.isEmpty ?? true) ? nil : requestedTeamID)
        guard migrationTeamID != nil else {
            pairedMacBackupLog.warning(
                "paired-mac legacy migration requires a server-verified team"
            )
            return primary.requiringMigrationRetry()
        }
        let migrationScope = PairedMacBackupMigrationScope(
            currentScope: currentScope,
            legacyScope: legacyScope,
            teamID: migrationTeamID,
            expectedUserID: capturedUserID
        )
        let migrationKey = migrationScope.key
        if let migrationKey,
           let lastReconciled = migrationDefaults.object(forKey: migrationKey) as? Date {
            let elapsed = migrationClock().timeIntervalSince(lastReconciled)
            if elapsed >= 0, elapsed < Self.legacyMigrationRecheckInterval {
                return primary
            }
        }
        guard let legacyResponse = await fetchSnapshotResponse(
            teamID: migrationTeamID,
            expectedUserID: capturedUserID,
            scope: .explicit(legacyScope)
        ) else { return primary.requiringMigrationRetry() }
        let legacy = legacyResponse.snapshot
        let migration = PairedMacBackupMigrationPlan(
            primary: primary,
            legacy: legacy
        )
        let migrationOps = migration.operations
        if migrationOps.isEmpty {
            if let migrationKey {
                migrationDefaults.set(migrationClock(), forKey: migrationKey)
            }
            return primary
        }
        let migrationBatch = Array(
            migrationOps.prefix(Self.maximumMigrationOperationsPerFetch)
        )
        if migrationBatch.count < migrationOps.count {
            pairedMacBackupLog.warning(
                "paired-mac legacy migration deferred after \(Self.maximumMigrationOperationsPerFetch) operations"
            )
        }
        guard let expectedRevision = primaryResponse.revision else {
            pairedMacBackupLog.warning(
                "paired-mac legacy migration requires server revision support"
            )
            return primary.requiringMigrationRetry()
        }
        guard await upload(
            ops: migrationBatch,
            teamID: migrationTeamID,
            expectedUserID: capturedUserID,
            routeDisclosureDate: Date(),
            expectedRevision: expectedRevision
        ) else {
            return primary.requiringMigrationRetry()
        }
        guard let refreshedResponse = await fetchSnapshotResponse(
            teamID: migrationTeamID,
            expectedUserID: capturedUserID,
            scope: .current
        ) else {
            return primary.requiringMigrationRetry()
        }
        let refreshed = refreshedResponse.snapshot
        if migration.isFullyReconciled(by: refreshed) {
            pairedMacBackupLog.debug("paired-mac legacy migration reconciled")
            if let migrationKey {
                migrationDefaults.set(migrationClock(), forKey: migrationKey)
            }
            return refreshed
        }
        return refreshed.requiringMigrationRetry()
    }

    private func fetchSnapshotResponse(
        teamID: String?,
        expectedUserID: String?,
        scope: PairedMacBackupClientScopeSelection
    ) async -> PairedMacFetchedSnapshot? {
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
            guard let response = try? JSONDecoder().decode(
                PairedMacBackupListResponse.self,
                from: data
            ) else {
                return nil
            }
            return PairedMacFetchedSnapshot(
                snapshot: response.snapshot,
                revision: response.revision
            )
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
