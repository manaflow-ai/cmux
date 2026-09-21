import CmuxAgentChat
import CmuxFoundation
import Foundation
import SwiftUI

/// Current-main extraction of the useful conversation-sidebar behavior from
/// the older fork experiment.
///
/// Open rows come from cmux's authoritative live agent registry. History and
/// transcript search come from the native Vault index. The two projections are
/// joined by canonical agent/session identity so a live conversation never
/// appears twice.
@MainActor
struct ConversationSidebarView: View {
    @ObservedObject var store: SessionIndexStore
    @ObservedObject var tabManager: TabManager

    @State private var searchText = ""
    @State private var searchResults: [SessionEntry] = []
    @State private var searchErrors: [String] = []
    @State private var isSearchInFlight = false
    @State private var expandedHistory: [SessionEntry] = []
    @State private var historyErrors: [String] = []
    @State private var isLoadingMoreHistory = false
    @State private var canLoadMoreHistory = true
    @State private var historyPerAgentLimit = SessionIndexStore.perAgentLimit
    @State private var visibleHistoryCount = 24
    @State private var liveSessionRevision: UInt64 = 0
    @State private var livePresentationAgentsByDirectory: [String: [String: SessionAgent]] = [:]

    private static let pageSize = 24
    private let projection = ConversationSidebarProjection()

    private enum Destination {
        case indexed(SessionEntry)
        case live(workspaceID: UUID, panelID: UUID)
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let agent: SessionAgent
        let directory: String?
        let modified: Date
        let isOpen: Bool
        let isFocused: Bool
        let destination: Destination
    }

    /// Value-only row presentation. The LazyVStack never receives the
    /// observable Vault/TabManager stores; it gets a row snapshot plus an
    /// action closure, matching the sidebar/list snapshot-boundary rule.
    private struct RowView: View {
        let row: Row
        let onActivate: @MainActor () -> Void

        var body: some View {
            Button(action: onActivate) {
                HStack(alignment: .top, spacing: 9) {
                    SessionIndexSectionIconImage(icon: .agent(row.agent), size: 18)
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: 12.5, weight: row.isFocused ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 5) {
                            Text(row.agent.displayName)
                            if let directory = Self.directoryLabel(row.directory) {
                                Text("·")
                                Text(directory)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 4)
                            Text(row.modified, style: .relative)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    if row.isOpen {
                        Circle()
                            .fill(row.isFocused ? Color.accentColor : Color.secondary.opacity(0.6))
                            .frame(width: 6, height: 6)
                            .padding(.top, 6)
                            .accessibilityLabel(
                                row.isFocused
                                    ? String(localized: "sessionIndex.status.activeIndicator", defaultValue: "Active")
                                    : String(localized: "sessionIndex.row.open", defaultValue: "Open")
                            )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(row.isFocused ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                row.isOpen
                    ? String(localized: "sessionIndex.row.focusSession", defaultValue: "Focus Session")
                    : String(localized: "sessionIndex.row.openSession", defaultValue: "Open Session")
            )
            .accessibilityLabel(row.title)
        }

        private static func directoryLabel(_ cwd: String?) -> String? {
            guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cwd.isEmpty else {
                return nil
            }
            let name = URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
            return name.isEmpty ? cwd : name
        }
    }

    var body: some View {
        let projected = projectedRows(liveSessionRevision: liveSessionRevision)
        let rows = projected.rows
        let openRows = rows.filter(\.isOpen)
        let visibleHistoryRows = rows.filter { !$0.isOpen }
        let manager = tabManager
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canShowMoreHistory = projection.canShowMoreHistory(
            hasMoreLoadedHistory: projected.hasMoreLoadedHistory,
            searchIsEmpty: trimmedSearch.isEmpty, canLoadMoreHistory: canLoadMoreHistory,
            hasLoadedHistorySource: !store.entries.isEmpty || !expandedHistory.isEmpty
        )
        let showsHistorySection = projection.shouldShowHistorySection(
            hasVisibleHistory: !visibleHistoryRows.isEmpty,
            canShowMoreHistory: canShowMoreHistory
        )

        VStack(spacing: 0) {
            searchField

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !openRows.isEmpty {
                        sectionLabel(
                            String(localized: "sessionIndex.row.open", defaultValue: "Open")
                        )
                        ForEach(openRows) { row in
                            RowView(row: row) {
                                Self.activate(row, tabManager: manager)
                            }
                        }
                    }

                    if showsHistorySection {
                        sectionLabel(
                            String(localized: "menu.history.title", defaultValue: "History")
                        )
                        ForEach(visibleHistoryRows) { row in
                            RowView(row: row) {
                                Self.activate(row, tabManager: manager)
                            }
                        }

                        if canShowMoreHistory {
                            Button {
                                visibleHistoryCount += Self.pageSize
                                if trimmedSearch.isEmpty, canLoadMoreHistory, !projected.hasMoreLoadedHistory {
                                    Task { await loadMoreHistory() }
                                }
                            } label: {
                                Text(
                                    String(
                                        localized: "sessionIndex.section.showMore",
                                        defaultValue: "Show more"
                                    )
                                )
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingMoreHistory)
                        }

                        if isLoadingMoreHistory {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(
                                    String(
                                        localized: "sessionIndex.popover.loading",
                                        defaultValue: "Loading…"
                                    )
                                )
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                    }

                    if let error = trimmedSearch.isEmpty ? historyErrors.first : searchErrors.first {
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                    }

                    if (store.isLoading && trimmedSearch.isEmpty || isSearchInFlight) && rows.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(
                                isSearchInFlight
                                    ? String(localized: "sessionIndex.search.searching", defaultValue: "Searching…")
                                    : String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…")
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                    } else if rows.isEmpty, !showsHistorySection {
                        Text(
                            trimmedSearch.isEmpty
                                ? String(localized: "sessionIndex.empty.title", defaultValue: "Vault is empty")
                                : String(localized: "sessionIndex.search.noResults", defaultValue: "No matching sessions")
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.never)
        }
        .onAppear {
            // Share the same process-wide SessionIndexStore as Vault. Do not
            // restart an in-flight/full scan just because the user switches
            // back to the Conversations provider.
            if store.entries.isEmpty && !store.isLoading {
                store.reload()
            }
        }
        .task(id: searchText) {
            await updateSearchResults(for: searchText)
        }
        .modifier(ConversationSidebarLiveRefreshModifier(
            store: store,
            revision: $liveSessionRevision,
            presentationAgentsByDirectory: $livePresentationAgentsByDirectory
        ))
        .onChange(of: searchText) { _, newValue in
            visibleHistoryCount = Self.pageSize
            searchResults = []
            searchErrors = []
            isSearchInFlight = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                String(
                    localized: "sessionIndex.allSessions.searchPlaceholder",
                    defaultValue: "Search sessions…"
                ),
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 7)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func projectedRows(
        liveSessionRevision: UInt64
    ) -> (rows: [Row], hasMoreLoadedHistory: Bool) {
        _ = liveSessionRevision
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedKeys = Set(searchResults.map(VaultLiveSessionKeys.key(for:)))
        let live = authoritativeLiveRows()
        var openIDs = Set(live.map(\.id))
        let workspaceByID = projection.workspacesByID(tabManager.tabs)

        // The live chat registry is authoritative for new sessions. Retained
        // restore snapshots/live-process observations provide a fallback for a
        // managed session that is active but has not reached that registry.
        let historySource = trimmedSearch.isEmpty
            ? projection.recentHistory(initial: store.entries, expanded: expandedHistory)
            : searchResults
        var fallbackOpen: [Row] = []
        for entry in historySource {
            let key = VaultLiveSessionKeys.key(for: entry)
            guard !openIDs.contains(key), store.liveSessionKeys.contains(key),
                  let target = SessionEntryResumeCoordinator.activeTarget(
                    for: entry,
                    tabManager: tabManager
                  ) else {
                continue
            }
            let workspace = workspaceByID[target.workspaceID]
            fallbackOpen.append(
                Row(
                    id: key,
                    title: displayTitle(for: entry),
                    agent: entry.agent,
                    directory: entry.cwd,
                    modified: entry.modified,
                    isOpen: true,
                    isFocused: tabManager.selectedTabId == target.workspaceID
                        && workspace?.focusedPanelId == target.surfaceID,
                    destination: .live(
                        workspaceID: target.workspaceID,
                        panelID: target.surfaceID
                    )
                )
            )
            openIDs.insert(key)
        }

        let visibleOpen = (live + fallbackOpen)
            .filter { row in
                trimmedSearch.isEmpty
                    || projection.metadataMatches(
                        title: row.title,
                        agent: row.agent,
                        id: row.id,
                        directory: row.directory,
                        query: trimmedSearch
                    )
                    || matchedKeys.contains(row.id)
            }
            .sorted { lhs, rhs in
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                return lhs.id < rhs.id
            }

        let visibleHistory = projection.visibleHistoryEntries(
            source: historySource,
            excludingOpenIDs: openIDs,
            limit: visibleHistoryCount
        )
        let history = visibleHistory.entries.map { entry in
            Row(
                id: VaultLiveSessionKeys.key(for: entry),
                title: displayTitle(for: entry),
                agent: entry.agent,
                directory: entry.cwd,
                modified: entry.modified,
                isOpen: false,
                isFocused: false,
                destination: .indexed(entry)
            )
        }

        return (visibleOpen + history, visibleHistory.hasMore)
    }

    private func authoritativeLiveRows() -> [Row] {
        guard let service = TerminalController.shared.agentChatTranscriptService else {
            return []
        }

        let fallbackAgentsByID = projection.presentationAgentsByID(
            store.entries.map(\.agent) + store.agentOrder
        )
        let workspaceByPanelID = projection.workspacesByPanelID(tabManager.tabs)

        return service.sessionRecords(workspaceID: nil).compactMap { record in
            if case .ended = record.state {
                return nil
            }
            guard let panelID = record.surfaceID.flatMap(UUID.init(uuidString:)),
                  let workspace = workspaceByPanelID[panelID],
                  let agent = projection.presentationAgent(
                    for: record,
                    configuredAgentsByDirectory: livePresentationAgentsByDirectory,
                    fallbackAgentsByID: fallbackAgentsByID
                  ) else {
                return nil
            }

            let title = record.title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? agent.displayName

            return Row(
                id: projection.liveSessionKey(for: record),
                title: title,
                agent: agent,
                directory: record.workingDirectory,
                modified: record.lastActivityAt,
                isOpen: true,
                isFocused: tabManager.selectedTabId == workspace.id
                    && workspace.focusedPanelId == panelID,
                destination: .live(workspaceID: workspace.id, panelID: panelID)
            )
        }
    }

    private func loadMoreHistory() async {
        guard !isLoadingMoreHistory, canLoadMoreHistory else { return }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }

        let previousEntries = projection.recentHistory(
            initial: store.entries,
            expanded: expandedHistory
        )
        let nextLimit = projection.nextHistoryPerAgentLimit(
            current: historyPerAgentLimit
        )
        let outcome = await store.loadRecentSessions(
            limitPerAgent: projection.historyPagePerAgent,
            offsetPerAgent: historyPerAgentLimit
        )
        guard !Task.isCancelled else { return }

        historyErrors = outcome.errors
        let previousIDs = Set(previousEntries.map(\.id))
        let mergedHistory = projection.recentHistory(
            initial: expandedHistory.isEmpty ? store.entries : expandedHistory,
            expanded: outcome.entries
        )
        let nextIDs = Set(mergedHistory.map(\.id))
        expandedHistory = mergedHistory
        historyPerAgentLimit = nextLimit
        canLoadMoreHistory = nextIDs.subtracting(previousIDs).isEmpty == false
            && nextLimit < SessionIndexStore.searchMaxFiles
    }

    private func updateSearchResults(for rawQuery: String) async {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchErrors = []
            isSearchInFlight = false
            return
        }

        isSearchInFlight = true
        // `.task(id: searchText)` cancels the previous search. The short
        // debounce keeps rapid typing from starting one full-disk search per
        // keystroke while preserving cancellation for the final query.
        try? await ContinuousClock().sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let outcome = await store.searchAllSessions(rawQuery: trimmed)
        guard !Task.isCancelled else { return }
        searchResults = outcome.entries
        searchErrors = outcome.errors
        isSearchInFlight = false
    }

    private static func activate(_ row: Row, tabManager: TabManager) {
        switch row.destination {
        case .live(let workspaceID, let panelID):
            tabManager.focusTab(workspaceID, surfaceId: panelID)
        case .indexed(let entry):
            if SessionEntryResumeCoordinator.focusIfActive(entry, tabManager: tabManager) {
                return
            }
            SessionEntryResumeCoordinator.open(entry, tabManager: tabManager)
        }
    }

    private func displayTitle(for entry: SessionEntry) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? entry.agent.displayName : trimmed
    }
}
