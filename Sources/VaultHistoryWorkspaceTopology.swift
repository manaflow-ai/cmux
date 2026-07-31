import Foundation

/// Immutable workspace, terminal, and agent-session topology rendered by History.
///
/// Live values are captured on the main actor, then the History model and AppKit
/// table receive only value snapshots. A restored workspace therefore has the
/// same shape as a workspace that never left the current process.
struct VaultHistoryWorkspaceTopology: Equatable, Sendable {
    enum WorkspaceState: Equatable, Sendable {
        case active
        case closed
    }

    enum AgentState: Equatable, Sendable {
        case running
        case restoring
        case hibernated
        case saved
    }

    struct AgentSession: Equatable, Sendable {
        let agent: SessionAgent
        let sessionId: String
        let title: String?
        let updatedAt: Date
        let state: AgentState
    }

    struct Terminal: Equatable, Sendable {
        let id: UUID
        let stableId: UUID?
        let title: String
        let directory: String?
        let agentSessions: [AgentSession]
    }

    struct Workspace: Equatable, Sendable {
        let id: String
        let workspaceId: UUID?
        let stableId: UUID?
        let windowId: UUID?
        let windowLabel: String?
        let title: String
        let directory: String?
        let timestamp: Date
        let state: WorkspaceState
        let isSelected: Bool
        let closedItemId: UUID?
        let terminals: [Terminal]
    }

    let workspaces: [Workspace]

    @MainActor
    struct Snapshotter {
        func capture(
            fallbackTabManager: TabManager,
            closedRecords: [ClosedItemHistoryRecord]
        ) -> VaultHistoryWorkspaceTopology {
            let active = activeWorkspaces(fallbackTabManager: fallbackTabManager)
            let activeIdentities = Set(active.flatMap(Self.workspaceIdentityCandidates))
            let closed = closedWorkspaces(from: closedRecords).filter { workspace in
                activeIdentities.isDisjoint(with: Self.workspaceIdentityCandidates(workspace))
            }
            return VaultHistoryWorkspaceTopology(workspaces: active + closed)
        }

        private func activeWorkspaces(fallbackTabManager: TabManager) -> [Workspace] {
            var windowSources: [(windowId: UUID?, manager: TabManager, isKey: Bool)] = []
            if let appDelegate = AppDelegate.shared {
                windowSources = appDelegate.listMainWindowSummaries().compactMap { summary in
                    appDelegate.tabManagerFor(windowId: summary.windowId).map {
                        (windowId: summary.windowId, manager: $0, isKey: summary.isKeyWindow)
                    }
                }
            }
            if !windowSources.contains(where: { $0.manager === fallbackTabManager }) {
                windowSources.append((
                    windowId: AppDelegate.shared?.windowId(for: fallbackTabManager),
                    manager: fallbackTabManager,
                    isKey: fallbackTabManager.window?.isKeyWindow ?? false
                ))
            }
            windowSources.sort { lhs, rhs in
                if lhs.isKey != rhs.isKey { return lhs.isKey }
                return (lhs.windowId?.uuidString ?? "") < (rhs.windowId?.uuidString ?? "")
            }

            var seenManagers: Set<ObjectIdentifier> = []
            let uniqueSources = windowSources.filter {
                seenManagers.insert(ObjectIdentifier($0.manager)).inserted
            }
            let showsWindowLabels = uniqueSources.count > 1
            let liveIndex = SharedLiveAgentIndex.shared.index

            return uniqueSources.enumerated().flatMap { windowIndex, source in
                let windowLabel = showsWindowLabels
                    ? String(
                        format: String(localized: "vaultHistory.window.numbered", defaultValue: "Window %d"),
                        windowIndex + 1
                    )
                    : nil
                return source.manager.tabs.map { workspace in
                    let terminals = workspace.sidebarOrderedPanelIds().compactMap { panelId -> Terminal? in
                        guard let terminal = workspace.panels[panelId] as? TerminalPanel else {
                            return nil
                        }
                        let directory = Self.normalized(workspace.panelDirectories[panelId])
                            ?? Self.normalized(terminal.directory)
                            ?? Self.normalized(terminal.requestedWorkingDirectory)
                        let title = Self.normalized(
                            workspace.panelTitle(panelId: panelId) ?? terminal.displayTitle
                        ) ?? ""
                        let indexedEntry = liveIndex?.entry(
                            workspaceId: workspace.id,
                            panelId: panelId
                        )
                        let hibernatedSnapshot = terminal.agentHibernationState?.agent
                        let restoredSnapshot = workspace.restoredAgentSnapshotsByPanelId[panelId]
                        let agentSnapshot = indexedEntry?.snapshot
                            ?? hibernatedSnapshot
                            ?? restoredSnapshot
                        let restoredState: AgentState? = switch workspace
                            .restoredAgentResumeStatesByPanelId[panelId] {
                        case .autoResumeCommandRunning, .awaitingAutoResumeCommand:
                            .restoring
                        case .observedAgentCommandRunning:
                            .running
                        case .manualResumeAvailable, .completedAgentExit:
                            .saved
                        case nil:
                            nil
                        }
                        let agentSessions = agentSnapshot.map { snapshot in
                            [
                                AgentSession(
                                    agent: Self.sessionAgent(for: snapshot),
                                    sessionId: snapshot.sessionId,
                                    title: nil,
                                    updatedAt: indexedEntry.map {
                                        Date(timeIntervalSince1970: $0.updatedAt)
                                    } ?? workspace.createdAt,
                                    state: Self.agentState(
                                        indexedEntry: indexedEntry,
                                        hasHibernatedSnapshot: hibernatedSnapshot != nil,
                                        restoredState: restoredState,
                                        hasRestoredSnapshot: restoredSnapshot != nil
                                    )
                                ),
                            ]
                        } ?? []
                        return Terminal(
                            id: panelId,
                            stableId: terminal.stableSurfaceId,
                            title: title,
                            directory: directory,
                            agentSessions: agentSessions
                        )
                    }
                    let title = Self.normalized(
                        source.manager.resolvedWorkspaceDisplayTitle(for: workspace)
                    ) ?? ""
                    return Workspace(
                        id: Self.workspaceIdentity(
                            workspaceId: workspace.id,
                            stableId: workspace.stableId
                        ),
                        workspaceId: workspace.id,
                        stableId: workspace.stableId,
                        windowId: source.windowId,
                        windowLabel: windowLabel,
                        title: title,
                        directory: Self.normalized(workspace.currentDirectory),
                        timestamp: workspace.createdAt,
                        state: .active,
                        isSelected: source.manager.selectedTabId == workspace.id,
                        closedItemId: nil,
                        terminals: terminals
                    )
                }
            }
        }

        private func closedWorkspaces(from records: [ClosedItemHistoryRecord]) -> [Workspace] {
            var result: [Workspace] = []
            var seen: Set<String> = []
            for record in records.sorted(by: { $0.closedAt > $1.closedAt }) {
                switch record.entry {
                case .panel:
                    continue
                case .workspace(let entry):
                    let workspace = closedWorkspace(
                        snapshot: entry.snapshot,
                        windowId: entry.windowId,
                        closedAt: record.closedAt,
                        closedItemId: record.id,
                        fallbackId: record.id.uuidString
                    )
                    if seen.insert(workspace.id).inserted {
                        result.append(workspace)
                    }
                case .window(let entry):
                    for (index, snapshot) in entry.snapshot.tabManager.workspaces.enumerated() {
                        let workspace = closedWorkspace(
                            snapshot: snapshot,
                            windowId: entry.windowId ?? entry.snapshot.windowId,
                            closedAt: record.closedAt,
                            closedItemId: record.id,
                            fallbackId: "\(record.id.uuidString):\(index)"
                        )
                        if seen.insert(workspace.id).inserted {
                            result.append(workspace)
                        }
                    }
                }
            }
            return result
        }

        private func closedWorkspace(
            snapshot: SessionWorkspaceSnapshot,
            windowId: UUID?,
            closedAt: Date,
            closedItemId: UUID,
            fallbackId: String
        ) -> Workspace {
            let terminals = snapshot.panels.compactMap { panel -> Terminal? in
                guard panel.type == .terminal else { return nil }
                let agentSessions = panel.terminal?.agent.map { agent in
                    [
                        AgentSession(
                            agent: Self.sessionAgent(for: agent),
                            sessionId: agent.sessionId,
                            title: nil,
                            updatedAt: closedAt,
                            state: .saved
                        ),
                    ]
                } ?? []
                return Terminal(
                    id: panel.id,
                    stableId: panel.stableSurfaceId,
                    title: Self.normalized(panel.customTitle ?? panel.title) ?? "",
                    directory: Self.normalized(panel.directory ?? panel.terminal?.workingDirectory),
                    agentSessions: agentSessions
                )
            }
            let title = Self.normalized(snapshot.customTitle)
                ?? Self.normalized(snapshot.processTitle)
                ?? Self.normalized((snapshot.currentDirectory as NSString).lastPathComponent)
                ?? ""
            return Workspace(
                id: snapshot.workspaceId.map {
                    Self.workspaceIdentity(workspaceId: $0, stableId: snapshot.stableId)
                } ?? snapshot.stableId.map { "workspace-stable:\($0.uuidString)" }
                    ?? "closed-workspace:\(fallbackId)",
                workspaceId: snapshot.workspaceId,
                stableId: snapshot.stableId,
                windowId: windowId,
                windowLabel: nil,
                title: title,
                directory: Self.normalized(snapshot.currentDirectory),
                timestamp: closedAt,
                state: .closed,
                isSelected: false,
                closedItemId: closedItemId,
                terminals: terminals
            )
        }

        static func agentState(
            indexedEntry: RestorableAgentSessionIndex.Entry?,
            hasHibernatedSnapshot: Bool,
            restoredState: AgentState?,
            hasRestoredSnapshot: Bool
        ) -> AgentState {
            if indexedEntry?.processIDs.isEmpty == false { return .running }
            if hasHibernatedSnapshot { return .hibernated }
            if let restoredState { return restoredState }
            if hasRestoredSnapshot { return .saved }
            return .saved
        }

        private static func sessionAgent(
            for snapshot: SessionRestorableAgentSnapshot
        ) -> SessionAgent {
            if let registration = snapshot.registration {
                return .registered(RegisteredSessionAgent(registration: registration))
            }
            if let builtIn = SessionAgent(rawValue: snapshot.kind.rawValue),
               SessionAgent.builtInCases.contains(builtIn) {
                return builtIn
            }
            return .registered(RegisteredSessionAgent(
                id: snapshot.kind.rawValue,
                name: snapshot.kind.displayName
            ))
        }

        private static func workspaceIdentity(workspaceId: UUID, stableId: UUID?) -> String {
            if let stableId {
                return "workspace-stable:\(stableId.uuidString)"
            }
            return "workspace:\(workspaceId.uuidString)"
        }

        private static func workspaceIdentityCandidates(_ workspace: Workspace) -> [String] {
            [
                workspace.workspaceId.map { "workspace:\($0.uuidString)" },
                workspace.stableId.map { "workspace-stable:\($0.uuidString)" },
            ].compactMap { $0 }
        }

        private static func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty || trimmed == "." ? nil : trimmed
        }
    }
}
