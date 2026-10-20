import AppKit
import Foundation
import Observation
import CmuxBrowser

struct BrowserOpenTabSuggestionSnapshot: Equatable {
    let host: PanelHost
    let workspaceId: UUID
    let panelId: UUID
    let url: String
    let title: String?
    let lowercasedURL: String
    let lowercasedTitle: String

    init?(
        host: PanelHost,
        panelId: UUID,
        url: String?,
        title: String?
    ) {
        guard let normalizedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalizedURL.isEmpty else { return nil }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host
        self.workspaceId = host.ownerID
        self.panelId = panelId
        self.url = normalizedURL
        self.title = normalizedTitle?.isEmpty == false ? normalizedTitle : nil
        self.lowercasedURL = normalizedURL.lowercased()
        self.lowercasedTitle = self.title?.lowercased() ?? ""
    }

    init?(
        workspaceId: UUID,
        panelId: UUID,
        url: String?,
        title: String?
    ) {
        self.init(
            host: .workspace(workspaceId),
            panelId: panelId,
            url: url,
            title: title
        )
    }
}

struct OmnibarOpenTabMatch: Equatable {
    let host: PanelHost
    let tabId: UUID
    let panelId: UUID
    let url: String
    let title: String?
    let isKnownOpenTab: Bool

    init(
        host: PanelHost,
        panelId: UUID,
        url: String,
        title: String?,
        isKnownOpenTab: Bool = true
    ) {
        self.host = host
        self.tabId = host.ownerID
        self.panelId = panelId
        self.url = url
        self.title = title
        self.isKnownOpenTab = isKnownOpenTab
    }

    init(
        tabId: UUID,
        panelId: UUID,
        url: String,
        title: String?,
        isKnownOpenTab: Bool = true
    ) {
        self.init(
            host: .workspace(tabId),
            panelId: panelId,
            url: url,
            title: title,
            isKnownOpenTab: isKnownOpenTab
        )
    }
}

extension BrowserHistoryStore {
    static func uiTestSeedEntriesIfConfigured() -> [Entry]? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MODE"] == "1",
              let rawSeed = env["CMUX_UI_TEST_BROWSER_HISTORY_JSON"],
              let data = rawSeed.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }
}

final class BrowserOpenTabSuggestionIndex {
    private var suggestionsByPanelId: [UUID: BrowserOpenTabSuggestionSnapshot] = [:]
    private var suggestionOrder: [UUID] = []
    private var isSeeded = false

    func upsert(_ snapshot: BrowserOpenTabSuggestionSnapshot) {
        let existing = suggestionsByPanelId[snapshot.panelId]
        guard existing != snapshot else { return }
        suggestionsByPanelId[snapshot.panelId] = snapshot
        if existing == nil {
            suggestionOrder.append(snapshot.panelId)
        }
    }

    func remove(panelId: UUID) {
        guard suggestionsByPanelId.removeValue(forKey: panelId) != nil else { return }
        suggestionOrder.removeAll { $0 == panelId }
    }

    func matching(
        for query: String,
        currentWorkspaceId: UUID,
        currentHost: PanelHost? = nil,
        currentPanelId: UUID,
        currentPanelSnapshot: BrowserOpenTabSuggestionSnapshot?,
        includeCurrentPanelForSingleCharacterQuery: Bool,
        limit: Int,
        seedSnapshots: () -> [BrowserOpenTabSuggestionSnapshot]
    ) -> [OmnibarOpenTabMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, limit > 0 else { return [] }

        seedIfNeeded(seedSnapshots)

        let loweredQuery = trimmedQuery.lowercased()
        let singleCharacterQuery = omnibarSingleCharacterQuery(for: trimmedQuery)
        let resolvedCurrentHost = currentHost
            ?? .workspace(currentWorkspaceId)
        var matches: [OmnibarOpenTabMatch] = []
        matches.reserveCapacity(min(limit, suggestionOrder.count + 1))
        var seenKeys = Set<String>()

        func snapshotMatches(_ snapshot: BrowserOpenTabSuggestionSnapshot) -> Bool {
            if let singleCharacterQuery {
                return omnibarHasSingleCharacterPrefixMatch(
                    query: singleCharacterQuery,
                    url: snapshot.url,
                    title: snapshot.title
                )
            }
            return snapshot.lowercasedURL.contains(loweredQuery) ||
                snapshot.lowercasedTitle.contains(loweredQuery)
        }

        func append(_ snapshot: BrowserOpenTabSuggestionSnapshot, isKnownOpenTab: Bool) {
            guard matches.count < limit else { return }
            let key = [
                snapshot.host.identityKey,
                snapshot.panelId.uuidString.lowercased(),
                snapshot.lowercasedURL,
            ].joined(separator: "|")
            guard snapshotMatches(snapshot) else { return }
            guard seenKeys.insert(key).inserted else { return }
            matches.append(
                OmnibarOpenTabMatch(
                    host: snapshot.host,
                    panelId: snapshot.panelId,
                    url: snapshot.url,
                    title: snapshot.title,
                    isKnownOpenTab: isKnownOpenTab
                )
            )
        }

        if includeCurrentPanelForSingleCharacterQuery, let currentPanelSnapshot {
            append(currentPanelSnapshot, isKnownOpenTab: true)
        }

        for panelId in suggestionOrder {
            guard matches.count < limit else { break }
            guard let snapshot = suggestionsByPanelId[panelId] else { continue }
            let isCurrentPanel = snapshot.host == resolvedCurrentHost &&
                snapshot.panelId == currentPanelId
            if isCurrentPanel && !includeCurrentPanelForSingleCharacterQuery {
                continue
            }
            append(snapshot, isKnownOpenTab: true)
        }

        return matches
    }

    private func seedIfNeeded(_ snapshots: () -> [BrowserOpenTabSuggestionSnapshot]) {
        guard !isSeeded else { return }
        isSeeded = true
        suggestionsByPanelId.removeAll(keepingCapacity: true)
        suggestionOrder.removeAll(keepingCapacity: true)
        for snapshot in snapshots() {
            suggestionsByPanelId[snapshot.panelId] = snapshot
            suggestionOrder.append(snapshot.panelId)
        }
    }
}

@MainActor
@Observable
final class OmnibarSuggestionRefreshScheduler {
    let refreshStream: AsyncStream<UInt64>

    @ObservationIgnored private var refreshContinuation: AsyncStream<UInt64>.Continuation
    @ObservationIgnored private var debounceDelay: Duration
    @ObservationIgnored private var clock: any OmnibarSuggestionRefreshClock
    @ObservationIgnored private var refreshGeneration: UInt64 = 0
    @ObservationIgnored private var pendingRefreshTask: Task<Void, Never>?

    init(
        debounceDelay: Duration = .milliseconds(80),
        clock: any OmnibarSuggestionRefreshClock = ContinuousOmnibarSuggestionRefreshClock()
    ) {
        self.debounceDelay = debounceDelay
        self.clock = clock
        let refreshPipe = AsyncStream<UInt64>.makeStream()
        refreshStream = refreshPipe.stream
        refreshContinuation = refreshPipe.continuation
    }

    func scheduleRefresh() {
        pendingRefreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let debounceDelay = debounceDelay
        let clock = clock
        pendingRefreshTask = Task { @MainActor [weak self, generation, debounceDelay, clock] in
            guard !Task.isCancelled else { return }
            do {
                try await clock.sleep(for: debounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard refreshGeneration == generation else { return }
            pendingRefreshTask = nil
            refreshContinuation.yield(generation)
        }
    }

    func cancelPendingRefresh() {
        refreshGeneration &+= 1
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
    }

    func shouldProcessRefresh(_ generation: UInt64) -> Bool {
        refreshGeneration == generation
    }
}

protocol OmnibarSuggestionRefreshClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousOmnibarSuggestionRefreshClock: OmnibarSuggestionRefreshClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

private var browserOpenTabSuggestionIndexesByManagerId: [ObjectIdentifier: BrowserOpenTabSuggestionIndex] = [:]

extension TabManager {
    private var browserOpenTabSuggestionIndex: BrowserOpenTabSuggestionIndex {
        let managerId = ObjectIdentifier(self)
        if let index = browserOpenTabSuggestionIndexesByManagerId[managerId] {
            return index
        }
        let index = BrowserOpenTabSuggestionIndex()
        browserOpenTabSuggestionIndexesByManagerId[managerId] = index
        return index
    }

    func upsertBrowserOpenTabSuggestion(_ snapshot: BrowserOpenTabSuggestionSnapshot) {
        browserOpenTabSuggestionIndex.upsert(snapshot)
    }

    func removeBrowserOpenTabSuggestion(panelId: UUID) {
        browserOpenTabSuggestionIndex.remove(panelId: panelId)
    }

    func matchingOpenBrowserTabSuggestions(
        for query: String,
        currentWorkspaceId: UUID,
        currentHost: PanelHost? = nil,
        currentPanelId: UUID,
        currentPanelSnapshot: BrowserOpenTabSuggestionSnapshot?,
        includeCurrentPanelForSingleCharacterQuery: Bool,
        limit: Int
    ) -> [OmnibarOpenTabMatch] {
        browserOpenTabSuggestionIndex.matching(
            for: query,
            currentWorkspaceId: currentWorkspaceId,
            currentHost: currentHost,
            currentPanelId: currentPanelId,
            currentPanelSnapshot: currentPanelSnapshot,
            includeCurrentPanelForSingleCharacterQuery: includeCurrentPanelForSingleCharacterQuery,
            limit: limit,
            seedSnapshots: browserOpenTabSuggestionSeedSnapshots
        )
    }

    private func browserOpenTabSuggestionSeedSnapshots() -> [BrowserOpenTabSuggestionSnapshot] {
        let workspaceSnapshots = tabs.flatMap { workspace in
            workspace.panels.compactMap { _, panel -> BrowserOpenTabSuggestionSnapshot? in
                guard let browserPanel = panel as? BrowserPanel else { return nil }
                return BrowserOpenTabSuggestionSnapshot(
                    workspaceId: workspace.id,
                    panelId: browserPanel.id,
                    url: browserPanel.preferredURLStringForOmnibar(),
                    title: browserPanel.pageTitle
                )
            }
        }
        let dockSnapshots = DockSplitStore.liveStores
            .filter {
                AppDelegate.shared?.dockReferenceTabManager(for: $0) === self
            }
            .flatMap { dock in
                dock.panels.values.compactMap { panel -> BrowserOpenTabSuggestionSnapshot? in
                    guard let browser = panel as? BrowserPanel else {
                        return nil
                    }
                    let host: PanelHost = dock.scope == .global
                        ? .windowDock(dock.workspaceId)
                        : .workspaceDock(dock.workspaceId)
                    return BrowserOpenTabSuggestionSnapshot(
                        host: host,
                        panelId: browser.id,
                        url: browser.preferredURLStringForOmnibar(),
                        title: browser.pageTitle
                    )
                }
            }
        return workspaceSnapshots + dockSnapshots
    }
}

extension DockSplitStore {
    func publishBrowserOpenTabSuggestion(for browserPanel: BrowserPanel) {
        guard let manager = AppDelegate.shared?.dockReferenceTabManager(
            for: self
        ) else {
            return
        }
        let host: PanelHost = scope == .global
            ? .windowDock(workspaceId)
            : .workspaceDock(workspaceId)
        guard let snapshot = BrowserOpenTabSuggestionSnapshot(
            host: host,
            panelId: browserPanel.id,
            url: browserPanel.preferredURLStringForOmnibar(),
            title: browserPanel.pageTitle
        ) else {
            manager.removeBrowserOpenTabSuggestion(panelId: browserPanel.id)
            return
        }
        manager.upsertBrowserOpenTabSuggestion(snapshot)
    }

    func removeBrowserOpenTabSuggestion(panelId: UUID) {
        AppDelegate.shared?.dockReferenceTabManager(for: self)?
            .removeBrowserOpenTabSuggestion(panelId: panelId)
    }
}

extension Workspace {
    func publishBrowserOpenTabSuggestion(for browserPanel: BrowserPanel) {
        guard let snapshot = BrowserOpenTabSuggestionSnapshot(
            workspaceId: id,
            panelId: browserPanel.id,
            url: browserPanel.preferredURLStringForOmnibar(),
            title: browserPanel.pageTitle
        ) else {
            owningTabManager?.removeBrowserOpenTabSuggestion(panelId: browserPanel.id)
            return
        }
        owningTabManager?.upsertBrowserOpenTabSuggestion(snapshot)
    }

    func removeBrowserOpenTabSuggestion(panelId: UUID) {
        owningTabManager?.removeBrowserOpenTabSuggestion(panelId: panelId)
    }

    func removeBrowserOpenTabSuggestionIfNeeded(panel: (any Panel)?, panelId: UUID) {
        guard panel is BrowserPanel else { return }
        removeBrowserOpenTabSuggestion(panelId: panelId)
    }
}

extension Notification.Name {
    static let commandPaletteVisibilityDidChange = Notification.Name("cmux.commandPaletteVisibilityDidChange")
}

func postCommandPaletteVisibilityDidChangeIfNeeded(
    wasVisible: Bool,
    visible: Bool,
    window: NSWindow,
    windowId: UUID
) {
    guard wasVisible != visible else { return }
    NotificationCenter.default.post(
        name: .commandPaletteVisibilityDidChange,
        object: window,
        userInfo: [
            "windowId": windowId,
            "visible": visible,
        ]
    )
}
