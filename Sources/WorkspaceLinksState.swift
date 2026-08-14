import Combine
import CmuxTerminalCore
import Foundation

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

/// The workspace-owned URL capture state. A separate `ObservableObject`, like
/// `WorkspaceTodoState`, so link churn publishes through its own object instead
/// of invalidating unrelated `Workspace` observers.
@MainActor
final class WorkspaceLinksState: ObservableObject {
    @Published private(set) var entries: [WorkspaceCapturedLink] = []

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

        let hostKey = CapturedLinkHostPolicy.hostKey(for: trimmed)
        if CapturedLinkHostPolicy.matchesIgnoreList(
            hostPort: hostKey,
            list: configuration.ignoreHosts
        ) {
            return nil
        }

        if let existingIndex = entries.firstIndex(where: { $0.url == trimmed }) {
            var entry = entries.remove(at: existingIndex)
            entry.lastSeen = now
            entry.count += 1
            entry.sourcePanelId = sourcePanelId ?? entry.sourcePanelId
            entry.sourceSurfaceTitle = sourceSurfaceTitle ?? entry.sourceSurfaceTitle
            entry.origin = origin
            entries.insert(entry, at: 0)
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
        entries.insert(entry, at: 0)
        enforceRetention(configuration.retentionLimit)
        return entry
    }

    func restore(_ restoredEntries: [WorkspaceCapturedLink], retentionLimit: Int) {
        let cap = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(retentionLimit)
        entries = Array(restoredEntries.sorted { $0.lastSeen > $1.lastSeen }.prefix(cap))
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func clearAll() {
        entries.removeAll()
    }

    func setFetchedTitle(_ title: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].fetchedTitle = title
    }

    private func enforceRetention(_ limit: Int) {
        let cap = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(limit)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
    }
}

enum WorkspaceLinksDayGrouping {
    static func dayKey(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}
