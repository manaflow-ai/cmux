import CmuxTerminalCore
import Foundation
import Observation

enum WorkspaceCapturedLinkOrigin: String, Codable, Hashable, Sendable {
    case osc8
    case detected

    init(_ source: TerminalCapturedLink.Source) {
        switch source {
        case .osc8: self = .osc8
        case .detected: self = .detected
        }
    }
}

enum WorkspaceLinkTitleFetchState: Hashable, Sendable {
    case idle
    case inFlight
    case failed
}

struct WorkspaceCapturedLink: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var url: String
    var hostKey: String?
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
    var sourcePanelId: UUID?
    var sourceSurfaceTitle: String?
    var origin: WorkspaceCapturedLinkOrigin
    var fetchedTitle: String?
    var titleFetchState: WorkspaceLinkTitleFetchState = .idle
}

struct WorkspaceLinksIngestConfiguration: Equatable, Sendable {
    var includeFilePaths: Bool
    var ignoreHosts: [String]
    var retentionLimit: Int

    init(
        includeFilePaths: Bool = false,
        ignoreHosts: [String] = ["localhost:31034"],
        retentionLimit: Int = 500
    ) {
        self.includeFilePaths = includeFilePaths
        self.ignoreHosts = ignoreHosts
        self.retentionLimit = Self.clampedRetentionLimit(retentionLimit)
    }

    static func clampedRetentionLimit(_ value: Int) -> Int {
        min(max(value, 10), 10_000)
    }
}

/// The workspace-owned URL capture state, isolated from unrelated workspace churn.
@MainActor
@Observable
final class WorkspaceLinksState {
    private var revision: UInt64 = 0

    @ObservationIgnored private var entriesByURL: [String: WorkspaceCapturedLink] = [:]
    @ObservationIgnored private var urlByID: [UUID: String] = [:]
    @ObservationIgnored private var previousURL: [String: String] = [:]
    @ObservationIgnored private var nextURL: [String: String] = [:]
    @ObservationIgnored private var headURL: String?
    @ObservationIgnored private var tailURL: String?
    @ObservationIgnored private let hostPolicy = CapturedLinkHostPolicy()

    var entries: [WorkspaceCapturedLink] {
        _ = revision
        return orderedEntries()
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
            if entry.fetchedTitle == nil {
                entry.titleFetchState = .idle
            }
            entriesByURL[trimmed] = entry
            moveToFront(trimmed)
            enforceRetention(configuration.retentionLimit)
            markChanged()
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
        markChanged()
        return entry
    }

    func restore(_ restoredEntries: [WorkspaceCapturedLink], retentionLimit: Int) {
        let cap = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(retentionLimit)
        clearStorage()
        for entry in restoredEntries.sorted(by: { $0.lastSeen > $1.lastSeen }).prefix(cap) {
            guard entriesByURL[entry.url] == nil else { continue }
            entriesByURL[entry.url] = entry
            urlByID[entry.id] = entry.url
            appendToTail(entry.url)
        }
        markChanged()
    }

    func remove(id: UUID) {
        guard let url = urlByID[id] else { return }
        removeURL(url)
        markChanged()
    }

    func clearAll() {
        clearStorage()
        markChanged()
    }

    func setFetchedTitle(_ title: String, for id: UUID) {
        guard let url = urlByID[id],
              var entry = entriesByURL[url] else { return }
        entry.fetchedTitle = title
        entry.titleFetchState = .idle
        entriesByURL[url] = entry
        markChanged()
    }

    func beginTitleFetch(for id: UUID) -> WorkspaceCapturedLink? {
        guard let url = urlByID[id],
              var entry = entriesByURL[url],
              entry.fetchedTitle == nil,
              entry.titleFetchState == .idle else {
            return nil
        }
        entry.titleFetchState = .inFlight
        entriesByURL[url] = entry
        markChanged()
        return entry
    }

    func finishTitleFetch(for id: UUID, title: String?) {
        guard let url = urlByID[id], var entry = entriesByURL[url] else { return }
        entry.fetchedTitle = title
        entry.titleFetchState = title == nil ? .failed : .idle
        entriesByURL[url] = entry
        markChanged()
    }

    func cancelTitleFetch(for id: UUID) {
        guard let url = urlByID[id],
              var entry = entriesByURL[url],
              entry.titleFetchState == .inFlight else {
            return
        }
        entry.titleFetchState = .idle
        entriesByURL[url] = entry
        markChanged()
    }

    func applyRetentionLimit(_ limit: Int) {
        let previousCount = entriesByURL.count
        enforceRetention(limit)
        if entriesByURL.count != previousCount {
            markChanged()
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

    private func markChanged() {
        revision &+= 1
    }
}
