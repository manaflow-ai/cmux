import Foundation
import SwiftUI

@MainActor
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

    func workspacesByID(_ workspaces: [Workspace]) -> [UUID: Workspace] {
        Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
    }

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

    func visibleHistoryEntries(
        source: [SessionEntry],
        excludingOpenIDs openIDs: Set<String>,
        limit: Int
    ) -> (entries: [SessionEntry], hasMore: Bool) {
        guard limit > 0 else {
            return ([], source.contains { !openIDs.contains(VaultLiveSessionKeys.key(for: $0)) })
        }
        var entries: [SessionEntry] = []
        entries.reserveCapacity(min(limit, source.count))
        for entry in source where !openIDs.contains(VaultLiveSessionKeys.key(for: entry)) {
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
struct ConversationSidebarLiveRefreshModifier: ViewModifier {
    let store: SessionIndexStore
    @Binding var revision: UInt64
    @Binding var presentationAgentsByDirectory: [String: [String: SessionAgent]]
    @State private var loadedDirectoryKeys: Set<String> = []
    private let projection = ConversationSidebarProjection()

    func body(content: Content) -> some View {
        content
            .task {
                await refreshPresentationAgents()
                for await _ in NotificationCenter.default.notifications(
                    named: .agentChatSessionRecordsDidChange
                ) {
                    guard !Task.isCancelled else { return }
                    revision &+= 1
                    await refreshPresentationAgents()
                }
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
        let missingDirectoryKeys = requiredDirectoryKeys.subtracting(loadedDirectoryKeys)
        guard !missingDirectoryKeys.isEmpty else { return }

        var next = presentationAgentsByDirectory
        for directoryKey in missingDirectoryKeys.sorted() {
            let loaded = await SessionIndexStore.defaultAgentOrder(
                workingDirectory: directoryKey.isEmpty ? nil : directoryKey
            )
            guard !Task.isCancelled else { return }
            next[directoryKey] = projection.presentationAgentsByID(loaded.agents)
        }
        presentationAgentsByDirectory = next
        loadedDirectoryKeys.formUnion(missingDirectoryKeys)
    }
}
