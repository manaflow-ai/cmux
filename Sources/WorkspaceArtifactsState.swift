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
    private static let sourcePanelMetadataKey = "sourcePanelID"
    private static let sourceTitleMetadataKey = "sourceSurfaceTitle"

    private enum PersistenceEvent: Sendable {
        case record(ArtifactRecord)
        case snapshot([ArtifactRecord])
    }

    private(set) var structuralRevision: UInt64 = 0
    private(set) var persistenceRevision: UInt64 = 0
    private(set) var latestTitleChange: WorkspaceLinkTitleChange?
    private(set) var fetchTitlesEnabled: Bool
    private(set) var retentionLimit: Int
    private(set) var isLoading = false
    private(set) var lastRepositoryError: String?
    private var didLoadRepositoryProjection = false

    private(set) var records: [ArtifactRecord] = []
    private var recordsByIdentity: [String: ArtifactRecord] = [:]
    private var orderByID: [UUID: UInt64] = [:]
    private var nextOrder: UInt64 = 0
    private var titleStateByID: [UUID: WorkspaceLinkTitleFetchState] = [:]
    private var titleGenerationByID: [UUID: UInt64] = [:]
    private var activeTitleFetchIDByID: [UUID: UUID] = [:]
    private var titleRetryAfterByID: [UUID: Date] = [:]
    private var titleChangeSequence: UInt64 = 0
    private var recentTitleChanges: [WorkspaceLinkTitleChange] = []
    private let hostPolicy = CapturedLinkHostPolicy()
    private let identity = ArtifactIdentity()
    private let repository: (any ArtifactStoring)?
    private let workspaceID: UUID?
    private var workingDirectory: String?
    // Swift 6 makes `deinit` nonisolated. These handles are only assigned and
    // consumed by the main-actor lifecycle, while the deinitializer performs
    // the final stream/task cancellation after isolation has ended.
    private nonisolated(unsafe) var persistenceContinuation: AsyncStream<PersistenceEvent>.Continuation?
    private nonisolated(unsafe) var persistenceTask: Task<Void, Never>?
    private var persistenceNeedsResync = false

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
            enqueue(record: record)
        }
        markStructuralChange()
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
            enqueue(record: record)
        }
        markStructuralChange()
    }

    /// Removes one record through the shared mutation path.
    func remove(id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        recordsByIdentity.removeValue(forKey: record.identityKey)
        records = ordered(recordsByIdentity.values)
        markStructuralChange()
        if let repository { Task { try? await repository.remove(id: id) } }
    }

    /// Clears this workspace's records while preserving other workspaces.
    func clearAll() {
        guard !records.isEmpty else { return }
        clearProjection()
        markStructuralChange()
        if let repository, let workspaceID {
            Task { try? await repository.clear(scope: .workspace(workspaceID.uuidString)) }
        }
    }

    /// Applies the Links-compatible retention/title settings to the artifact projection.
    func applyRetentionLimit(_ limit: Int) {
        let clamped = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(limit)
        retentionLimit = clamped
        let before = records.count
        records = Array(ordered(recordsByIdentity.values).prefix(clamped))
        recordsByIdentity = Dictionary(uniqueKeysWithValues: records.map { ($0.identityKey, $0) })
        if before != records.count {
            markStructuralChange()
            enqueueSnapshot()
        }
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
        persistenceRevision &+= 1
        enqueue(record: updated)
    }

    /// Cancels a title request if its request id is still current.
    func cancelTitleFetch(for id: UUID, requestID: UUID) {
        guard activeTitleFetchIDByID[id] == requestID else { return }
        activeTitleFetchIDByID[id] = nil
        titleStateByID[id] = .idle
    }

    private var ownership: ArtifactOwnership {
        ArtifactOwnership(
            workspaceID: workspaceID?.uuidString,
            projectID: workingDirectory.map { identity.stableTextDigest($0) },
            projectRoot: workingDirectory,
            workspaceTitle: nil
        )
    }

    private func merge(_ incoming: ArtifactRecord, at date: Date) -> ArtifactRecord {
        if let existing = recordsByIdentity[incoming.identityKey] {
            let updated = existing.merging(source: incoming.source, lastSeenAt: date, title: incoming.title, metadata: incoming.metadata)
            recordsByIdentity[incoming.identityKey] = updated
            records = ordered(recordsByIdentity.values)
            return updated
        }
        recordsByIdentity[incoming.identityKey] = incoming
        nextOrder &+= 1
        orderByID[incoming.id] = nextOrder
        records = ordered(recordsByIdentity.values)
        if records.count > retentionLimit, let oldest = records.last {
            recordsByIdentity.removeValue(forKey: oldest.identityKey)
            orderByID.removeValue(forKey: oldest.id)
            records.removeLast()
        }
        return incoming
    }

    private func captureInMemory(_ request: ArtifactIngestRequest, capturedAt: Date) -> ArtifactRecord? {
        let representation: ArtifactRepresentation
        let kind: ArtifactKind
        let identityValue: String
        switch request.input {
        case .url(let value):
            guard let canonical = identity.canonicalURL(value) else { return nil }
            representation = .url(canonical); kind = request.kind ?? .url; identityValue = canonical
        case .html(let value): representation = .inlineHTML(value); kind = request.kind ?? .html; identityValue = value
        case .text(let value): representation = .inlineText(value); kind = request.kind ?? .text; identityValue = value
        case .directory(let url): representation = .directory(path: url.path); kind = .directory; identityValue = url.path
        case .file, .data: return nil
        }
        let record = ArtifactRecord(kind: kind, identityKey: identity.key(kind: kind == .url ? .url : kind, value: identityValue, ownership: ownership), ownership: ownership, source: request.source, createdAt: capturedAt, lastSeenAt: capturedAt, title: request.title, metadata: request.metadata, representation: representation, isUserOwned: request.authorization == .explicitUser)
        let merged = merge(record, at: capturedAt)
        markStructuralChange()
        return merged
    }

    private func upsertProjection(_ record: ArtifactRecord) {
        if let existing = recordsByIdentity[record.identityKey], existing.id != record.id {
            recordsByIdentity[record.identityKey] = existing.merging(source: record.source, lastSeenAt: record.lastSeenAt, title: record.title, metadata: record.metadata, occurrenceIncrement: max(0, record.occurrenceCount - 1))
        } else {
            recordsByIdentity[record.identityKey] = record
            nextOrder &+= 1
            orderByID[record.id] = nextOrder
        }
        records = Array(ordered(recordsByIdentity.values).prefix(retentionLimit))
        recordsByIdentity = Dictionary(uniqueKeysWithValues: records.map { ($0.identityKey, $0) })
    }

    private func clearProjection() {
        records.removeAll(keepingCapacity: true)
        recordsByIdentity.removeAll(keepingCapacity: true)
        orderByID.removeAll(keepingCapacity: true)
        titleStateByID.removeAll(); titleGenerationByID.removeAll(); activeTitleFetchIDByID.removeAll(); titleRetryAfterByID.removeAll()
    }

    private func markStructuralChange() {
        structuralRevision &+= 1
        persistenceRevision &+= 1
    }

    private func enqueue(record: ArtifactRecord) {
        guard let continuation = persistenceContinuation else { return }
        if case .dropped = continuation.yield(.record(record)), !persistenceNeedsResync {
            persistenceNeedsResync = true
            _ = continuation.yield(.snapshot(records))
            persistenceNeedsResync = false
        }
    }

    private func enqueueSnapshot() {
        guard let continuation = persistenceContinuation else { return }
        _ = continuation.yield(.snapshot(records))
    }

    private func linkEntry(for record: ArtifactRecord) -> WorkspaceCapturedLink? {
        guard record.kind == .url || record.kind == .file else { return nil }
        let url: String
        switch record.representation {
        case .url(let value): url = value
        case .directory, .managedFile, .inlineText, .inlineHTML: return nil
        }
        let sourcePanelID = record.metadata[Self.sourcePanelMetadataKey].flatMap(UUID.init(uuidString:))
        let sourceTitle = record.metadata[Self.sourceTitleMetadataKey]
        let hostKey = URL(string: url).flatMap { hostPolicy.hostKey(for: $0.absoluteString) }
        let origin: WorkspaceCapturedLinkOrigin = record.source == .terminalOSC8 ? .osc8 : .detected
        return WorkspaceCapturedLink(id: record.id, url: url, hostKey: hostKey, firstSeen: record.createdAt, lastSeen: record.lastSeenAt, count: record.occurrenceCount, sourcePanelId: sourcePanelID, sourceSurfaceTitle: sourceTitle, origin: origin, fetchedTitle: record.title, titleFetchState: titleStateByID[record.id, default: .idle], titleFetchGeneration: titleGenerationByID[record.id, default: 0], activeTitleFetchID: activeTitleFetchIDByID[record.id], titleFetchRetryAfter: titleRetryAfterByID[record.id])
    }

    private func record(from entry: WorkspaceCapturedLink) -> ArtifactRecord {
        var metadata: [String: String] = [:]
        if let sourcePanelId = entry.sourcePanelId { metadata[Self.sourcePanelMetadataKey] = sourcePanelId.uuidString }
        if let sourceSurfaceTitle = entry.sourceSurfaceTitle { metadata[Self.sourceTitleMetadataKey] = sourceSurfaceTitle }
        return ArtifactRecord(id: entry.id, kind: entry.url.lowercased().hasPrefix("file://") ? .file : .url, identityKey: identity.key(kind: .url, value: entry.url, ownership: ownership), ownership: ownership, source: .migratedLink, createdAt: entry.firstSeen, lastSeenAt: entry.lastSeen, occurrenceCount: entry.count, title: entry.fetchedTitle, metadata: metadata, representation: .url(entry.url))
    }

    private func ordered<S: Sequence>(_ values: S) -> [ArtifactRecord] where S.Element == ArtifactRecord {
        values.sorted {
            if $0.lastSeenAt != $1.lastSeenAt { return $0.lastSeenAt > $1.lastSeenAt }
            let lhsOrder = orderByID[$0.id, default: 0]
            let rhsOrder = orderByID[$1.id, default: 0]
            if lhsOrder != rhsOrder { return lhsOrder > rhsOrder }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
