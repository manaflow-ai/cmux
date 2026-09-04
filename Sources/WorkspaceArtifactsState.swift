import CmuxArtifacts
import CmuxTerminalCore
import Foundation
import Observation

/// Main-actor projection of the canonical artifact catalog.
///
/// The repository actor owns durable records. This projection keeps the current
/// workspace rows and title-fetch lifecycle synchronous for existing terminal
/// callbacks, then hands mutations to one bounded persistence stream. The
/// `WorkspaceLinksState` typealias is retained solely for snapshot/source
/// compatibility with the first Links-panel release.
@MainActor
@Observable
final class WorkspaceArtifactsState {
    private static let maximumRecentTitleChanges = 256
    private static let titleFetchRetryCooldown: TimeInterval = 60
    static let sourcePanelMetadataKey = "sourcePanelID"
    static let sourceTitleMetadataKey = "sourceSurfaceTitle"

    enum PersistenceEvent: Sendable {
        case record(ArtifactRecord)
        case snapshot([ArtifactRecord])
        case remove(UUID)
        case clear(ArtifactScope)
        case retention(Int)
    }

    internal(set) var structuralRevision: UInt64 = 0
    internal(set) var persistenceRevision: UInt64 = 0
    private(set) var latestTitleChange: WorkspaceLinkTitleChange?
    private(set) var fetchTitlesEnabled: Bool
    internal(set) var retentionLimit: Int
    private(set) var isLoading = false
    private(set) var lastRepositoryError: String?
    private var didLoadRepositoryProjection = false

    internal(set) var records: [ArtifactRecord] = []
    var recordsByIdentity: [String: ArtifactRecord] = [:]
    var orderByID: [UUID: UInt64] = [:]
    var nextOrder: UInt64 = 0
    var titleStateByID: [UUID: WorkspaceLinkTitleFetchState] = [:]
    var titleGenerationByID: [UUID: UInt64] = [:]
    var activeTitleFetchIDByID: [UUID: UUID] = [:]
    var titleRetryAfterByID: [UUID: Date] = [:]
    private var titleChangeSequence: UInt64 = 0
    private var recentTitleChanges: [WorkspaceLinkTitleChange] = []
    let hostPolicy = CapturedLinkHostPolicy()
    let identity = ArtifactIdentity()
    private let repository: (any ArtifactStoring)?
    let workspaceID: UUID?
    var workingDirectory: String?
    // Swift 6 makes `deinit` nonisolated. These handles are only assigned and
    // consumed by the main-actor lifecycle, while the deinitializer performs
    // the final stream/task cancellation after isolation has ended.
    nonisolated(unsafe) var persistenceContinuation: AsyncStream<PersistenceEvent>.Continuation?
    nonisolated(unsafe) var persistenceTask: Task<Void, Never>?
    var persistenceNeedsResync = false

    /// The injected catalog used by global scope and action routing.
    var artifactRepository: (any ArtifactStoring)? { repository }

    /// Creates a workspace projection, optionally backed by the process catalog.
    ///
    /// - Parameters:
    ///   - repository: Shared durable repository. `nil` keeps isolated unit-test
    ///     projections in memory.
    ///   - workspaceID: Stable workspace owner used for global filtering.
    ///   - workingDirectory: Current project root/capture context.
    ///   - retentionLimit: Initial per-workspace row cap.
    ///   - fetchTitlesEnabled: Whether public URL title fetching is allowed.
    init(
        repository: (any ArtifactStoring)? = nil,
        workspaceID: UUID? = nil,
        workingDirectory: String? = nil,
        retentionLimit: Int = 500,
        fetchTitlesEnabled: Bool = false
    ) {
        self.repository = repository
        self.workspaceID = workspaceID
        self.workingDirectory = workingDirectory
        self.retentionLimit = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(retentionLimit)
        self.fetchTitlesEnabled = fetchTitlesEnabled

        guard let repository else { return }
        let (stream, continuation) = AsyncStream<PersistenceEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        self.persistenceContinuation = continuation
        self.persistenceTask = Task {
            for await event in stream {
                guard !Task.isCancelled else { break }
                do {
                    switch event {
                    case .record(let record):
                        try await repository.upsert(record)
                    case .snapshot(let records):
                        let owner = records.first?.ownership.workspaceID ?? workspaceID?.uuidString ?? ""
                        try await repository.replace(records: records, scope: .workspace(owner))
                    case .remove(let id):
                        try await repository.remove(id: id)
                    case .clear(let scope):
                        try await repository.clear(scope: scope)
                    case .retention(let limit):
                        try await repository.updateRetentionLimit(limit)
                    }
                } catch {
                    // The projection remains usable while a later mutation or
                    // explicit refresh retries the durable write.
                }
            }
        }
    }

    deinit {
        persistenceContinuation?.finish()
        persistenceTask?.cancel()
    }

    /// Updates the path context used by subsequent explicit captures.
    func updateWorkingDirectory(_ path: String?) {
        workingDirectory = path?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All records currently projected for this workspace, newest first.
    var artifactRecords: [ArtifactRecord] {
        _ = structuralRevision
        return records
    }

    /// URL/file-compatible rows retained for the Links compatibility surface.
    var entries: [WorkspaceCapturedLink] {
        _ = structuralRevision
        return records.compactMap(linkEntry(for:))
    }

    /// Returns one record by stable identity.
    func artifact(for id: UUID) -> ArtifactRecord? {
        records.first { $0.id == id }
    }

    /// Returns one compatibility URL row by stable identity.
    func entry(for id: UUID) -> WorkspaceCapturedLink? {
        records.first(where: { $0.id == id }).flatMap(linkEntry(for:))
    }

    /// Returns title changes after a sequence, or `nil` when a complete projection is required.
    func titleChanges(after sequence: UInt64) -> [WorkspaceLinkTitleChange]? {
        guard let firstChange = recentTitleChanges.first else { return [] }
        guard sequence >= firstChange.sequence - 1 else { return nil }
        return recentTitleChanges.filter { $0.sequence > sequence }
    }

    /// Captures one terminal-emitted URL through the canonical artifact path.
    @discardableResult
    func ingest(
        url: String,
        origin: WorkspaceCapturedLinkOrigin,
        sourcePanelId: UUID?,
        sourceSurfaceTitle: String?,
        configuration: WorkspaceLinksIngestConfiguration,
        now: Date = .now,
        id: UUID = UUID()
    ) -> WorkspaceCapturedLink? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        let isFile = lower.hasPrefix("file://")
        guard !isFile || configuration.includeFilePaths else { return nil }
        guard isFile || lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        if !isFile,
           let hostKey = hostPolicy.hostKey(for: trimmed),
           hostPolicy.matchesIgnoreList(hostPort: hostKey, list: configuration.ignoreHosts) {
            return nil
        }

        if retentionLimit != configuration.retentionLimit {
            applyRetentionLimit(configuration.retentionLimit)
        }

        let canonical = isFile ? trimmed : (identity.canonicalURL(trimmed) ?? trimmed)
        var metadata: [String: String] = [:]
        if let sourcePanelId { metadata[Self.sourcePanelMetadataKey] = sourcePanelId.uuidString }
        if let sourceSurfaceTitle { metadata[Self.sourceTitleMetadataKey] = sourceSurfaceTitle }
        if let hostKey = hostPolicy.hostKey(for: trimmed) { metadata["host"] = hostKey }
        let source: ArtifactSource = {
            switch origin {
            case .osc8: return .terminalOSC8
            case .detected: return isFile ? .terminalPath : .terminalURL
            }
        }()
        let kind: ArtifactKind = isFile ? .file : .url
        let record = ArtifactRecord(
            id: id,
            kind: kind,
            identityKey: identity.key(kind: .url, value: canonical, ownership: ownership),
            ownership: ownership,
            source: source,
            createdAt: now,
            lastSeenAt: now,
            occurrenceCount: 1,
            metadata: metadata,
            representation: .url(canonical)
        )
        if let existing = recordsByIdentity[record.identityKey],
           titleStateByID[existing.id] == .failed,
           titleRetryAfterByID[existing.id].map({ now >= $0 }) ?? true {
            titleStateByID[existing.id] = .idle
            titleGenerationByID[existing.id, default: 0] &+= 1
            titleRetryAfterByID[existing.id] = nil
        }
        let merged = merge(record, at: now)
        markStructuralChange()
        enqueue(record: merged)
        return linkEntry(for: merged)
    }

    /// Captures a batch of terminal links with one structural revision.
    func ingest(
        _ links: [TerminalCapturedLink],
        sourcePanelId: UUID?,
        sourceSurfaceTitle: String?,
        configuration: WorkspaceLinksIngestConfiguration,
        now: Date = .now
    ) {
        let initialStructuralRevision = structuralRevision
        let initialPersistenceRevision = persistenceRevision
        var didChange = false
        for link in links {
            if ingest(
                url: link.url,
                origin: WorkspaceCapturedLinkOrigin(link.source),
                sourcePanelId: sourcePanelId,
                sourceSurfaceTitle: sourceSurfaceTitle,
                configuration: configuration,
                now: now
            ) != nil {
                didChange = true
            }
        }
        if didChange {
            structuralRevision = initialStructuralRevision + 1
            persistenceRevision = initialPersistenceRevision + 1
        }
    }

    /// Captures HTML, text, JSON, or producer-supplied bytes through the same repository.
    @discardableResult
    func capture(
        _ input: ArtifactInput,
        kind: ArtifactKind? = nil,
        source: ArtifactSource,
        title: String? = nil,
        metadata: [String: String] = [:],
        authorization: ArtifactCaptureAuthorization = .explicitUser,
        capturedAt: Date = .now
    ) async -> ArtifactRecord? {
        let request = ArtifactIngestRequest(
            input: input,
            kind: kind,
            ownership: ownership,
            source: source,
            title: title,
            metadata: metadata,
            authorization: authorization
        )
        guard let repository else { return captureInMemory(request, capturedAt: capturedAt) }
        do {
            let record = try await repository.ingest(request, capturedAt: capturedAt)
            upsertProjection(record)
            markStructuralChange()
            return record
        } catch {
            lastRepositoryError = String(describing: error)
            return nil
        }
    }

    /// Loads the authoritative workspace projection without scanning terminals.
    func refreshFromRepository() async {
        guard let repository, let workspaceID else { return }
        guard !didLoadRepositoryProjection else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await repository.list(scope: .workspace(workspaceID.uuidString))
            for record in loaded {
                if let existing = recordsByIdentity[record.identityKey] {
                    recordsByIdentity[record.identityKey] = existing.occurrenceCount >= record.occurrenceCount
                        ? existing
                        : record
                } else {
                    recordsByIdentity[record.identityKey] = record
                }
            }
            records = ordered(recordsByIdentity.values)
            orderByID = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, UInt64(records.count - $0.offset)) })
            didLoadRepositoryProjection = true
            markStructuralChange()
        } catch {
            lastRepositoryError = String(describing: error)
        }
    }

    /// Searches the global catalog through its bounded in-memory index.
    func globalRecords(
        query: String = "",
        limit: Int = 500,
        kind: ArtifactKind? = nil,
        kindGroup: ArtifactKindGroup? = nil,
        source: ArtifactSource? = nil,
        host: String? = nil
    ) async -> [ArtifactSearchResult] {
        guard let repository else { return [] }
        do {
            return try await repository.search(.init(
                text: query,
                scope: .global,
                limit: limit,
                kind: kind,
                kindGroup: kindGroup,
                source: source,
                host: host
            ))
        } catch {
            lastRepositoryError = String(describing: error)
            return []
        }
    }

    /// Resolves a file-backed record through the repository's authorization boundary.
    func materializedURL(for record: ArtifactRecord) async -> URL? {
        guard let repository else {
            if case .url(let value) = record.representation { return URL(string: value) }
            if case .directory(let path) = record.representation { return URL(fileURLWithPath: path) }
            return nil
        }
        return try? await repository.materializedURL(for: record)
    }

    /// Restores legacy Links rows and schedules their migration into the catalog.
    func restoreLegacyLinks(_ restoredEntries: [WorkspaceCapturedLink], retentionLimit: Int) {
        clearProjection()
        let cap = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(retentionLimit)
        for entry in restoredEntries.sorted(by: { $0.lastSeen > $1.lastSeen }).prefix(cap) {
            let record = record(from: entry)
            upsertProjection(record)
        }
        markStructuralChange()
        enqueueSnapshot()
    }

    /// Compatibility spelling used by the original Links snapshot adapter.
    func restore(_ restoredEntries: [WorkspaceCapturedLink], retentionLimit: Int) {
        restoreLegacyLinks(restoredEntries, retentionLimit: retentionLimit)
    }

    /// Restores new artifact records from a portable session snapshot.
    func restoreArtifacts(_ restoredRecords: [ArtifactRecord], retentionLimit: Int) {
        let cap = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(retentionLimit)
        for record in restoredRecords.sorted(by: { $0.lastSeenAt > $1.lastSeenAt }).prefix(cap) {
            upsertProjection(record)
        }
        markStructuralChange()
        enqueueSnapshot()
    }

    /// Removes one record through the shared mutation path.
    func remove(id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        recordsByIdentity.removeValue(forKey: record.identityKey)
        orderByID.removeValue(forKey: record.id)
        titleStateByID.removeValue(forKey: record.id)
        titleGenerationByID.removeValue(forKey: record.id)
        activeTitleFetchIDByID.removeValue(forKey: record.id)
        titleRetryAfterByID.removeValue(forKey: record.id)
        records = ordered(recordsByIdentity.values)
        markStructuralChange()
        if repository != nil { enqueue(.remove(id)) }
    }

    /// Clears this workspace's records while preserving other workspaces.
    func clearAll() {
        guard !records.isEmpty else { return }
        clearProjection()
        markStructuralChange()
        if let workspaceID, repository != nil { enqueue(.clear(.workspace(workspaceID.uuidString))) }
    }

    /// Applies the Links-compatible retention/title settings to the artifact projection.
    func applyRetentionLimit(_ limit: Int) {
        let clamped = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(limit)
        let didChangeLimit = retentionLimit != clamped
        retentionLimit = clamped
        let before = records.count
        records = Array(ordered(recordsByIdentity.values).prefix(clamped))
        recordsByIdentity = Dictionary(uniqueKeysWithValues: records.map { ($0.identityKey, $0) })
        if before != records.count {
            let liveIDs = Set(records.map(\.id))
            orderByID = orderByID.filter { liveIDs.contains($0.key) }
            titleStateByID = titleStateByID.filter { liveIDs.contains($0.key) }
            titleGenerationByID = titleGenerationByID.filter { liveIDs.contains($0.key) }
            activeTitleFetchIDByID = activeTitleFetchIDByID.filter { liveIDs.contains($0.key) }
            titleRetryAfterByID = titleRetryAfterByID.filter { liveIDs.contains($0.key) }
            markStructuralChange()
            enqueueSnapshot()
        }
        if didChangeLimit, repository != nil { enqueue(.retention(clamped)) }
    }

    /// Applies live title-fetch settings without touching captured records unnecessarily.
    func applySettings(retentionLimit: Int, fetchTitlesEnabled: Bool) {
        applyRetentionLimit(retentionLimit)
        guard self.fetchTitlesEnabled != fetchTitlesEnabled else { return }
        self.fetchTitlesEnabled = fetchTitlesEnabled
        if !fetchTitlesEnabled {
            let inFlightIDs = activeTitleFetchIDByID.keys
            activeTitleFetchIDByID.removeAll()
            for id in inFlightIDs {
                titleStateByID[id] = .idle
                titleGenerationByID[id, default: 0] &+= 1
            }
            if !inFlightIDs.isEmpty { markStructuralChange() }
        }
    }

    /// Begins one guarded title request for a URL compatibility row.
    func beginTitleFetch(for id: UUID, requestID: UUID = UUID()) -> WorkspaceLinkTitleFetchRequest? {
        guard fetchTitlesEnabled,
              let entry = entry(for: id),
              entry.fetchedTitle == nil,
              titleStateByID[id, default: .idle] == .idle else { return nil }
        titleStateByID[id] = .inFlight
        activeTitleFetchIDByID[id] = requestID
        return WorkspaceLinkTitleFetchRequest(entry: entry, requestID: requestID)
    }

    /// Completes one guarded title request and persists the title metadata.
    func finishTitleFetch(for id: UUID, requestID: UUID, title: String?, now: Date = .now) {
        guard activeTitleFetchIDByID[id] == requestID,
              let record = records.first(where: { $0.id == id }) else { return }
        activeTitleFetchIDByID[id] = nil
        titleStateByID[id] = title == nil ? .failed : .idle
        titleRetryAfterByID[id] = title == nil ? now.addingTimeInterval(Self.titleFetchRetryCooldown) : nil
        let updated = record.withTitle(title)
        recordsByIdentity[record.identityKey] = updated
        records = ordered(recordsByIdentity.values)
        guard title != nil else { markStructuralChange(); return }
        titleChangeSequence &+= 1
        let change = WorkspaceLinkTitleChange(sequence: titleChangeSequence, entryID: id)
        recentTitleChanges.append(change)
        if recentTitleChanges.count > Self.maximumRecentTitleChanges {
            recentTitleChanges.removeFirst(recentTitleChanges.count - Self.maximumRecentTitleChanges)
        }
        latestTitleChange = change
        // Title updates are part of the visible row snapshot as well as the
        // durable record; invalidate the structural projection so both the
        // workspace pane and global-search reconciliation see the new title.
        markStructuralChange()
        enqueue(record: updated)
    }

    /// Cancels a title request if its request id is still current.
    func cancelTitleFetch(for id: UUID, requestID: UUID) {
        guard activeTitleFetchIDByID[id] == requestID else { return }
        activeTitleFetchIDByID[id] = nil
        titleStateByID[id] = .idle
    }

}
