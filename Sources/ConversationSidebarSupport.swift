import Foundation
import Observation
import SwiftUI

struct ConversationSidebarProjection {
    let historyPagePerAgent = 30

    func liveSessionKey(for record: AgentChatSessionRecord) -> String {
        VaultLiveSessionKeys.key(
            kind: record.agentKind.sourceName,
            sessionID: record.hookStoreLookupSessionID
        )
    }

    func presentationAgentsByID(_ agents: [SessionAgent]) -> [String: SessionAgent] {
        var result: [String: SessionAgent] = [:]
        result.reserveCapacity(agents.count)
        for agent in agents where result[agent.rawValue] == nil {
            result[agent.rawValue] = agent
        }
        return result
    }

    func presentationDirectoryKey(_ workingDirectory: String?) -> String {
        guard let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !directory.isEmpty else { return "" }
        return directory
    }

    func livePresentationDirectoryKeys(
        for records: [AgentChatSessionRecord]
    ) -> Set<String> {
        var keys: Set<String> = [""]
        for record in records {
            if case .ended = record.state { continue }
            keys.insert(presentationDirectoryKey(record.workingDirectory))
        }
        return keys
    }

    func presentationAgent(
        for record: AgentChatSessionRecord,
        configuredAgentsByDirectory: [String: [String: SessionAgent]],
        fallbackAgentsByID: [String: SessionAgent]
    ) -> SessionAgent? {
        let directoryKey = presentationDirectoryKey(record.workingDirectory)
        let configuredAgentsByID = configuredAgentsByDirectory[directoryKey]
            ?? configuredAgentsByDirectory[""]
            ?? fallbackAgentsByID
        // This fallback is presentation-only. Session identity and routing
        // continue to come from the authoritative agent-chat record.
        return configuredAgentsByID[record.agentKind.sourceName]
            ?? SessionAgent(rawValue: record.agentKind.sourceName)
    }

    @MainActor
    func workspacesByID(_ workspaces: [Workspace]) -> [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
    }

    @MainActor
    func workspacesByPanelID(_ workspaces: [Workspace]) -> [UUID: Workspace] {
        var result: [UUID: Workspace] = [:]
        for workspace in workspaces {
            for panelID in workspace.panels.keys {
                result[panelID] = workspace
            }
        }
        return result
    }

    /// Both inputs are newest-first Vault snapshots. The initial snapshot wins
    /// for overlapping ids because it carries the freshest metadata; older
    /// expanded rows fill only ids that fell outside the initial preview.
    func recentHistory(
        initial: [SessionEntry],
        expanded: [SessionEntry]
    ) -> [SessionEntry] {
        var seen = Set<String>()
        let current = initial.filter { seen.insert($0.id).inserted }
        guard !expanded.isEmpty else { return current }

        var older: [SessionEntry] = []
        older.reserveCapacity(expanded.count)
        for entry in expanded where seen.insert(entry.id).inserted {
            older.append(entry)
        }

        var result: [SessionEntry] = []
        result.reserveCapacity(current.count + older.count)
        var currentIndex = 0
        var olderIndex = 0
        while currentIndex < current.count, olderIndex < older.count {
            let lhs = current[currentIndex]
            let rhs = older[olderIndex]
            if lhs.modified > rhs.modified || (lhs.modified == rhs.modified && lhs.id < rhs.id) {
                result.append(lhs)
                currentIndex += 1
            } else {
                result.append(rhs)
                olderIndex += 1
            }
        }
        result.append(contentsOf: current[currentIndex...])
        result.append(contentsOf: older[olderIndex...])
        return result
    }

    func metadataMatches(
        title: String,
        agent: SessionAgent,
        id: String,
        directory: String?,
        query: String
    ) -> Bool {
        let terms = normalized(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = normalized([
            title,
            agent.displayName,
            id,
            directory ?? ""
        ].joined(separator: " "))
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Provider filtering is keyed by the stable agent id rather than the
    /// localized display name, so the selection remains valid when the
    /// app language or a registered agent's presentation changes.
    func providerFilterMatches(
        agent: SessionAgent,
        selectedProviderID: String?
    ) -> Bool {
        guard let selectedProviderID else { return true }
        return agent.rawValue == selectedProviderID
    }

    /// Build the menu from the unfiltered snapshot so searching and filtering
    /// cannot remove the current selection or other available providers.
    func providerFilterOptions(
        agents: [SessionAgent],
        preferredOrder: [SessionAgent],
        selectedProviderID: String?
    ) -> [SessionAgent] {
        var agentsByID = presentationAgentsByID(agents)
        if let selectedProviderID, agentsByID[selectedProviderID] == nil,
           let selected = preferredOrder.first(where: { $0.rawValue == selectedProviderID })
                ?? SessionAgent(rawValue: selectedProviderID) {
            agentsByID[selectedProviderID] = selected
        }
        var seen = Set<String>()
        let ordered = preferredOrder.compactMap { agent -> SessionAgent? in
            guard seen.insert(agent.rawValue).inserted else { return nil }
            return agentsByID[agent.rawValue]
        }
        let remaining = agentsByID.values.filter { !seen.contains($0.rawValue) }
            .sorted { $0.rawValue < $1.rawValue }
        return ordered + remaining
    }

    func visibleHistoryEntries(
        source: [SessionEntry],
        excludingOpenIDs openIDs: Set<String>,
        limit: Int,
        selectedProviderID: String? = nil
    ) -> (entries: [SessionEntry], hasMore: Bool) {
        guard limit > 0 else {
            return ([], source.contains {
                !openIDs.contains(VaultLiveSessionKeys.key(for: $0))
                    && providerFilterMatches(agent: $0.agent, selectedProviderID: selectedProviderID)
            })
        }
        var entries: [SessionEntry] = []
        entries.reserveCapacity(min(limit, source.count))
        for entry in source where !openIDs.contains(VaultLiveSessionKeys.key(for: entry))
            && providerFilterMatches(agent: entry.agent, selectedProviderID: selectedProviderID) {
            if entries.count == limit {
                return (entries, true)
            }
            entries.append(entry)
        }
        return (entries, false)
    }

    func canShowMoreHistory(
        hasMoreLoadedHistory: Bool,
        searchIsEmpty: Bool,
        canLoadMoreHistory: Bool,
        hasLoadedHistorySource: Bool
    ) -> Bool {
        hasMoreLoadedHistory
            || (searchIsEmpty && canLoadMoreHistory && hasLoadedHistorySource)
    }

    func shouldShowHistorySection(hasVisibleHistory: Bool, canShowMoreHistory: Bool) -> Bool {
        hasVisibleHistory || canShowMoreHistory
    }

    func nextHistoryPerAgentLimit(current: Int) -> Int {
        min(current + historyPagePerAgent, SessionIndexStore.searchMaxFiles)
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class ConversationSidebarRefreshScheduler {
    private final class PendingRefreshToken {}

    @ObservationIgnored
    private var pendingTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingToken: PendingRefreshToken?

    func schedule(_ operation: @escaping @MainActor () async -> Void) {
        pendingTask?.cancel()
        let token = PendingRefreshToken()
        pendingToken = token
        pendingTask = Task { @MainActor [weak self, token] in
            // Yield once so a synchronous burst of registry notifications
            // collapses into one trailing refresh without retaining a SwiftUI
            // State value that itself owns a closure-bearing Task.
            await Task.yield()
            guard !Task.isCancelled else { return }
            await operation()
            guard let self, self.pendingToken === token else { return }
            self.pendingTask = nil
            self.pendingToken = nil
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingToken = nil
    }

    deinit {
        pendingTask?.cancel()
    }
}

@MainActor
struct ConversationSidebarLiveRefreshModifier: ViewModifier {
    let store: SessionIndexStore
    @Binding var revision: UInt64
    @Binding var presentationAgentsByDirectory: [String: [String: SessionAgent]]
    @State private var refreshScheduler = ConversationSidebarRefreshScheduler()
    private let projection = ConversationSidebarProjection()

    func body(content: Content) -> some View {
        content
            .task {
                await refreshPresentationAgents()
                for await _ in NotificationCenter.default.notifications(
                    named: .agentChatSessionRecordsDidChange
                ) {
                    guard !Task.isCancelled else { return }
                    // Hook activity can emit several record invalidations per
                    // turn (pre-tool, post-tool, and transcript updates). A
                    // cancellable trailing task coalesces the burst while
                    // guaranteeing that the final state is eventually read.
                    refreshScheduler.schedule { @MainActor in
                        revision &+= 1
                        await refreshPresentationAgents()
                    }
                }
            }
            .onDisappear {
                refreshScheduler.cancel()
            }
            .task {
                for await _ in NotificationCenter.default.notifications(
                    named: .agentChatSessionHistoryDidChange
                ) {
                    guard !Task.isCancelled else { return }
                    store.reload()
                }
            }
    }

    private func refreshPresentationAgents() async {
        let records = TerminalController.shared.agentChatTranscriptService?
            .sessionRecords(workspaceID: nil) ?? []
        let requiredDirectoryKeys = projection.livePresentationDirectoryKeys(for: records)
        let staleDirectoryKeys = Set(presentationAgentsByDirectory.keys).subtracting(requiredDirectoryKeys)
        for directoryKey in staleDirectoryKeys {
            presentationAgentsByDirectory.removeValue(forKey: directoryKey)
        }
        let missingDirectoryKeys = requiredDirectoryKeys.subtracting(presentationAgentsByDirectory.keys)
        guard !missingDirectoryKeys.isEmpty else { return }

        for directoryKey in missingDirectoryKeys.sorted() {
            let loaded = await SessionIndexStore.defaultAgentOrder(
                workingDirectory: directoryKey.isEmpty ? nil : directoryKey
            )
            guard !Task.isCancelled else { return }
            presentationAgentsByDirectory[directoryKey] = projection.presentationAgentsByID(loaded.agents)
        }
    }
}
