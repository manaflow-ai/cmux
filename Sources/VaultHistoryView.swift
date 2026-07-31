import SwiftUI

/// The History timeline, combining workspace/window lifecycle events with agent sessions.
struct VaultHistoryView: View {
    let mode: VaultHistoryMode
    @ObservedObject private var tabManager: TabManager
    @ObservedObject private var sessionStore: SessionIndexStore
    @ObservedObject private var closedItemStore: ClosedItemHistoryStore
    private let log: VaultHistoryEventLog
    private let onResume: ((SessionEntry) -> Void)?
    private let onReopenClosedItem: ((UUID) -> Bool)?
    @State private var model: VaultHistoryTimelineModel

    init(
        mode: VaultHistoryMode,
        tabManager: TabManager,
        sessionStore: SessionIndexStore,
        closedItemStore: ClosedItemHistoryStore,
        log: VaultHistoryEventLog,
        onResume: ((SessionEntry) -> Void)?,
        onReopenClosedItem: ((UUID) -> Bool)?
    ) {
        self.mode = mode
        self.tabManager = tabManager
        self.sessionStore = sessionStore
        self.closedItemStore = closedItemStore
        self.log = log
        self.onResume = onResume
        self.onReopenClosedItem = onReopenClosedItem
        _model = State(initialValue: VaultHistoryTimelineModel(log: log, mode: mode))
    }

    var body: some View {
        VaultHistoryContentView(
            tabManager: tabManager,
            sessionStore: sessionStore,
            closedItemStore: closedItemStore,
            log: log,
            model: model,
            onResume: onResume,
            onReopenClosedItem: onReopenClosedItem
        )
        .onChange(of: mode) { _, mode in
            model.mode = mode
        }
    }
}

private struct VaultHistoryContentView: View {
    @ObservedObject var tabManager: TabManager
    @ObservedObject var sessionStore: SessionIndexStore
    @ObservedObject var closedItemStore: ClosedItemHistoryStore
    let log: VaultHistoryEventLog
    let model: VaultHistoryTimelineModel
    let onResume: ((SessionEntry) -> Void)?
    let onReopenClosedItem: ((UUID) -> Bool)?

    var body: some View {
        VStack(spacing: 0) {
            VaultHistoryControls(
                model: model,
                isReloadDisabled: model.isLoading || sessionStore.isLoading,
                onReload: reload
            )
            if !model.didLoad {
                VaultHistoryLoadingView()
            } else if model.groups.isEmpty && model.workspaceSections.isEmpty {
                VaultHistoryEmptyView(
                    hasActiveFilters: model.hasActiveFilters,
                    onClearFilters: model.clearFilters
                )
            } else {
                VaultHistoryTimelineList(
                    groups: model.groups,
                    workspaceSections: model.workspaceSections,
                    resumeEntriesByEventId: model.resumeEntriesByEventId,
                    availableClosedItemIds: closedItemStore.recordIdsSnapshot,
                    actions: VaultHistoryRowActions(
                        onResume: onResume,
                        onReopenClosedItem: onReopenClosedItem,
                        onActivateWorkspace: activateWorkspace,
                        onActivateTerminal: activateTerminal
                    )
                )
            }
        }
        .onAppear {
            if sessionStore.entries.isEmpty && !sessionStore.isLoading {
                sessionStore.reload()
            }
            refresh()
        }
        .onChange(of: sessionStore.entries) { _, entries in
            refresh(sessionEntries: entries)
        }
        .onChange(of: log.revision) { _, _ in
            refresh()
        }
        .onChange(of: closedItemStore.revision) { _, _ in
            refresh()
        }
        .onChange(of: tabManager.tabs.map(\.id)) { _, _ in
            refresh()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: .vaultHistoryLiveTopologyDidChange
            ) {
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: .sharedLiveAgentIndexDidChange
            ) {
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: .workspaceTitleDidChange
            ) {
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: .workspaceCurrentDirectoryDidChange
            ) {
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    private func reload() {
        sessionStore.reload()
        refresh()
    }

    @discardableResult
    private func activateWorkspace(_ workspaceId: UUID) -> Bool {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) ?? (
            tabManager.workspacesById[workspaceId] == nil ? nil : tabManager
        ),
        let workspace = manager.workspacesById[workspaceId] else {
            return false
        }
        focusWindow(for: manager)
        manager.selectWorkspace(workspace)
        return true
    }

    @discardableResult
    private func activateTerminal(_ workspaceId: UUID, _ terminalId: UUID) -> Bool {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) ?? (
            tabManager.workspacesById[workspaceId] == nil ? nil : tabManager
        ),
        let workspace = manager.workspacesById[workspaceId],
        workspace.panels[terminalId] != nil else {
            return false
        }
        focusWindow(for: manager)
        manager.selectWorkspace(workspace)
        workspace.focusPanel(terminalId)
        return true
    }

    private func focusWindow(for manager: TabManager) {
        guard let appDelegate = AppDelegate.shared,
              let windowId = appDelegate.windowId(for: manager) else {
            return
        }
        _ = appDelegate.focusScriptableMainWindow(
            windowId: windowId,
            bringToFront: true
        )
    }

    private func refresh(sessionEntries: [SessionEntry]? = nil) {
        let topology = VaultHistoryWorkspaceTopology.Snapshotter().capture(
            fallbackTabManager: tabManager,
            closedRecords: closedItemStore.recordsSnapshot
        )
        model.refresh(
            sessionEntries: sessionEntries ?? sessionStore.entries,
            topology: topology
        )
    }
}

private struct VaultHistoryLoadingView: View {
    var body: some View {
        VStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "vaultHistory.loading", defaultValue: "Loading history…"))
                .cmuxFont(size: 11)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct VaultHistoryEmptyView: View {
    let hasActiveFilters: Bool
    let onClearFilters: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
            Text(subtitle)
                .cmuxFont(size: 11)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            if hasActiveFilters {
                Button {
                    onClearFilters()
                } label: {
                    Text(String(localized: "vaultHistory.filters.clear", defaultValue: "Clear filters"))
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if hasActiveFilters {
            return String(localized: "vaultHistory.empty.filtered.title", defaultValue: "No matching history")
        }
        return String(localized: "vaultHistory.empty.title", defaultValue: "No history yet")
    }

    private var subtitle: String {
        if hasActiveFilters {
            return String(
                localized: "vaultHistory.empty.filtered.subtitle",
                defaultValue: "Try another search or time range."
            )
        }
        return String(
            localized: "vaultHistory.empty.subtitle",
            defaultValue: "Workspace, window, and agent session activity will appear here."
        )
    }
}
