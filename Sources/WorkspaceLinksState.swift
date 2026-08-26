import CmuxTerminalCore
import Foundation
import Observation

/// The workspace-owned URL capture state, isolated from unrelated workspace churn.
@MainActor
@Observable
final class WorkspaceLinksState {
    private static let maximumRecentTitleChanges = 256
    private static let titleFetchRetryCooldown: TimeInterval = 60

    private var persistenceRevisionValue: UInt64 = 0
    private var titleChangeSequence: UInt64 = 0
    private(set) var structuralRevision: UInt64 = 0
    private(set) var latestTitleChange: WorkspaceLinkTitleChange?
    private(set) var fetchTitlesEnabled: Bool
    private(set) var retentionLimit: Int

    @ObservationIgnored private var entriesByURL: [String: WorkspaceCapturedLink] = [:]
    @ObservationIgnored private var urlByID: [UUID: String] = [:]
    @ObservationIgnored private var previousURL: [String: String] = [:]
    @ObservationIgnored private var nextURL: [String: String] = [:]
    @ObservationIgnored private var headURL: String?
    @ObservationIgnored private var tailURL: String?
    @ObservationIgnored private var recentTitleChanges: [WorkspaceLinkTitleChange] = []
    @ObservationIgnored private let hostPolicy = CapturedLinkHostPolicy()

    init(retentionLimit: Int = 500, fetchTitlesEnabled: Bool = false) {
        self.retentionLimit = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(retentionLimit)
        self.fetchTitlesEnabled = fetchTitlesEnabled
    }

    var entries: [WorkspaceCapturedLink] {
        _ = structuralRevision
        return orderedEntries()
    }

    var persistenceRevision: UInt64 {
        persistenceRevisionValue
    }

    func entry(for id: UUID) -> WorkspaceCapturedLink? {
        urlByID[id].flatMap { entriesByURL[$0] }
    }

    func titleChanges(after sequence: UInt64) -> [WorkspaceLinkTitleChange]? {
        guard let firstChange = recentTitleChanges.first else { return [] }
        guard sequence >= firstChange.sequence - 1 else { return nil }
        return recentTitleChanges.filter { $0.sequence > sequence }
    }

    @discardableResult
    func ingest(
        url: String,
        origin: WorkspaceCapturedLinkOrigin,
        sourcePanelId: UUID?,
        sourceSurfaceTitle: String?,
        configuration: WorkspaceLinksIngestConfiguration,
        now: Date = Date(),
        id: UUID = UUID()
    ) -> WorkspaceCapturedLink? {
        guard let entry = ingestWithoutMarking(
            url: url,
            origin: origin,
            sourcePanelId: sourcePanelId,
            sourceSurfaceTitle: sourceSurfaceTitle,
            configuration: configuration,
            now: now,
            id: id
        ) else {
            return nil
        }
        markStructuralChange()
        return entry
    }

    func ingest(
        _ links: [TerminalCapturedLink],
        sourcePanelId: UUID?,
        sourceSurfaceTitle: String?,
        configuration: WorkspaceLinksIngestConfiguration,
        now: Date = .now
    ) {
        var didChange = false
        for link in links {
            if ingestWithoutMarking(
                url: link.url,
                origin: WorkspaceCapturedLinkOrigin(link.source),
                sourcePanelId: sourcePanelId,
                sourceSurfaceTitle: sourceSurfaceTitle,
                configuration: configuration,
                now: now,
                id: UUID()
            ) != nil {
                didChange = true
            }
        }
        if didChange {
            markStructuralChange()
        }
    }

    private func ingestWithoutMarking(
        url: String,
        origin: WorkspaceCapturedLinkOrigin,
        sourcePanelId: UUID?,
        sourceSurfaceTitle: String?,
        configuration: WorkspaceLinksIngestConfiguration,
        now: Date,
        id: UUID
    ) -> WorkspaceCapturedLink? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if !configuration.includeFilePaths,
           !lower.hasPrefix("http://"),
           !lower.hasPrefix("https://") {
            return nil
        }

        let hostKey = hostPolicy.hostKey(for: trimmed)
        if hostPolicy.matchesIgnoreList(
            hostPort: hostKey,
            list: configuration.ignoreHosts
        ) {
            return nil
        }

        if var entry = entriesByURL[trimmed] {
            entry.lastSeen = now
            entry.count += 1
            entry.sourcePanelId = sourcePanelId ?? entry.sourcePanelId
            entry.sourceSurfaceTitle = sourceSurfaceTitle ?? entry.sourceSurfaceTitle
            entry.origin = origin
            if entry.fetchedTitle == nil,
               entry.titleFetchState == .failed,
               entry.titleFetchRetryAfter.map({ now >= $0 }) ?? true {
                entry.titleFetchState = .idle
                entry.titleFetchGeneration &+= 1
                entry.titleFetchRetryAfter = nil
            }
            entriesByURL[trimmed] = entry
            moveToFront(trimmed)
            enforceRetention(configuration.retentionLimit)
            return entry
        }

        let entry = WorkspaceCapturedLink(
            id: id,
            url: trimmed,
            hostKey: hostKey,
            firstSeen: now,
            lastSeen: now,
            count: 1,
            sourcePanelId: sourcePanelId,
            sourceSurfaceTitle: sourceSurfaceTitle,
            origin: origin,
            fetchedTitle: nil
        )
        entriesByURL[trimmed] = entry
        urlByID[entry.id] = trimmed
        insertAtFront(trimmed)
        enforceRetention(configuration.retentionLimit)
        return entry
    }

    func restore(_ restoredEntries: [WorkspaceCapturedLink], retentionLimit: Int) {
        let cap = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(retentionLimit)
        clearStorage()
        for restoredEntry in restoredEntries.sorted(by: { $0.lastSeen > $1.lastSeen }).prefix(cap) {
            guard entriesByURL[restoredEntry.url] == nil else { continue }
            var entry = restoredEntry
            entry.titleFetchState = .idle
            entry.activeTitleFetchID = nil
            entry.titleFetchRetryAfter = nil
            entriesByURL[entry.url] = entry
            urlByID[entry.id] = entry.url
            appendToTail(entry.url)
        }
        markStructuralChange()
    }

    func remove(id: UUID) {
        guard let url = urlByID[id] else { return }
        removeURL(url)
        markStructuralChange()
    }

    func clearAll() {
        clearStorage()
        markStructuralChange()
    }

    func beginTitleFetch(
        for id: UUID,
        requestID: UUID = UUID()
    ) -> WorkspaceLinkTitleFetchRequest? {
        guard fetchTitlesEnabled,
              let url = urlByID[id],
              var entry = entriesByURL[url],
              entry.fetchedTitle == nil,
              entry.titleFetchState == .idle else {
            return nil
        }
        entry.titleFetchState = .inFlight
        entry.activeTitleFetchID = requestID
        entriesByURL[url] = entry
        return WorkspaceLinkTitleFetchRequest(entry: entry, requestID: requestID)
    }

    func finishTitleFetch(
        for id: UUID,
        requestID: UUID,
        title: String?,
        now: Date = .now
    ) {
        guard let url = urlByID[id],
              var entry = entriesByURL[url],
              entry.activeTitleFetchID == requestID else {
            return
        }
        entry.fetchedTitle = title
        entry.titleFetchState = title == nil ? .failed : .idle
        entry.activeTitleFetchID = nil
        entry.titleFetchRetryAfter = title == nil
            ? now.addingTimeInterval(Self.titleFetchRetryCooldown)
            : nil
        entriesByURL[url] = entry
        if title != nil {
            markTitleChange(entryID: id)
        }
    }

    func cancelTitleFetch(for id: UUID, requestID: UUID) {
        guard let url = urlByID[id],
              var entry = entriesByURL[url],
              entry.titleFetchState == .inFlight,
              entry.activeTitleFetchID == requestID else {
            return
        }
        entry.titleFetchState = .idle
        entry.activeTitleFetchID = nil
        entriesByURL[url] = entry
    }

    func applyRetentionLimit(_ limit: Int) {
        retentionLimit = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(limit)
        let previousCount = entriesByURL.count
        enforceRetention(retentionLimit)
        if entriesByURL.count != previousCount {
            markStructuralChange()
        }
    }

    func applySettings(retentionLimit: Int, fetchTitlesEnabled: Bool) {
        applyRetentionLimit(retentionLimit)
        guard self.fetchTitlesEnabled != fetchTitlesEnabled else { return }
        self.fetchTitlesEnabled = fetchTitlesEnabled
        if !fetchTitlesEnabled {
            resetInFlightTitleFetches()
        }
    }

    private func enforceRetention(_ limit: Int) {
        let cap = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(limit)
        while entriesByURL.count > cap, let tailURL {
            removeURL(tailURL)
        }
    }

    private func orderedEntries() -> [WorkspaceCapturedLink] {
        var result: [WorkspaceCapturedLink] = []
        result.reserveCapacity(entriesByURL.count)
        var cursor = headURL
        while let url = cursor {
            if let entry = entriesByURL[url] {
                result.append(entry)
            }
            cursor = nextURL[url]
        }
        return result
    }

    private func insertAtFront(_ url: String) {
        previousURL[url] = nil
        nextURL[url] = headURL
        if let headURL {
            previousURL[headURL] = url
        } else {
            tailURL = url
        }
        headURL = url
    }

    private func appendToTail(_ url: String) {
        nextURL[url] = nil
        previousURL[url] = tailURL
        if let tailURL {
            nextURL[tailURL] = url
        } else {
            headURL = url
        }
        tailURL = url
    }

    private func moveToFront(_ url: String) {
        guard headURL != url else { return }
        detach(url)
        insertAtFront(url)
    }

    private func removeURL(_ url: String) {
        detach(url)
        if let id = entriesByURL[url]?.id {
            urlByID[id] = nil
        }
        entriesByURL[url] = nil
    }

    private func detach(_ url: String) {
        let previous = previousURL[url]
        let next = nextURL[url]
        if let previous {
            nextURL[previous] = next
        } else if headURL == url {
            headURL = next
        }
        if let next {
            previousURL[next] = previous
        } else if tailURL == url {
            tailURL = previous
        }
        previousURL[url] = nil
        nextURL[url] = nil
    }

    private func clearStorage() {
        entriesByURL.removeAll(keepingCapacity: true)
        urlByID.removeAll(keepingCapacity: true)
        previousURL.removeAll(keepingCapacity: true)
        nextURL.removeAll(keepingCapacity: true)
        headURL = nil
        tailURL = nil
    }

    private func resetInFlightTitleFetches() {
        let inFlightURLs = entriesByURL.compactMap { url, entry in
            entry.titleFetchState == .inFlight ? url : nil
        }
        for url in inFlightURLs {
            guard var entry = entriesByURL[url] else { continue }
            entry.titleFetchState = .idle
            entry.titleFetchGeneration &+= 1
            entry.activeTitleFetchID = nil
            entriesByURL[url] = entry
        }
    }

    private func markStructuralChange() {
        persistenceRevisionValue &+= 1
        structuralRevision &+= 1
    }

    private func markTitleChange(entryID: UUID) {
        persistenceRevisionValue &+= 1
        titleChangeSequence &+= 1
        let change = WorkspaceLinkTitleChange(
            sequence: titleChangeSequence,
            entryID: entryID
        )
        recentTitleChanges.append(change)
        if recentTitleChanges.count > Self.maximumRecentTitleChanges {
            recentTitleChanges.removeFirst(
                recentTitleChanges.count - Self.maximumRecentTitleChanges
            )
        }
        latestTitleChange = change
    }
}
