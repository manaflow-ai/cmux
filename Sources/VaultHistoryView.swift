import SwiftUI

/// The History timeline, combining workspace/window lifecycle events with agent sessions.
struct VaultHistoryView: View {
    let mode: VaultHistoryMode
    @ObservedObject private var sessionStore: SessionIndexStore
    @ObservedObject private var closedItemStore: ClosedItemHistoryStore
    private let log: VaultHistoryEventLog
    private let onResume: ((SessionEntry) -> Void)?
    private let onReopenClosedItem: ((UUID) -> Bool)?
    @State private var model: VaultHistoryTimelineModel

    init(
        mode: VaultHistoryMode,
        sessionStore: SessionIndexStore,
        closedItemStore: ClosedItemHistoryStore,
        log: VaultHistoryEventLog,
        onResume: ((SessionEntry) -> Void)?,
        onReopenClosedItem: ((UUID) -> Bool)?
    ) {
        self.mode = mode
        self.sessionStore = sessionStore
        self.closedItemStore = closedItemStore
        self.log = log
        self.onResume = onResume
        self.onReopenClosedItem = onReopenClosedItem
        _model = State(initialValue: VaultHistoryTimelineModel(log: log, mode: mode))
    }

    var body: some View {
        VaultHistoryContentView(
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
            } else if model.groups.isEmpty {
                VaultHistoryEmptyView(
                    hasActiveFilters: model.hasActiveFilters,
                    onClearFilters: model.clearFilters
                )
            } else {
                VaultHistoryTimelineList(
                    groups: model.groups,
                    resumeEntriesByEventId: model.resumeEntriesByEventId,
                    availableClosedItemIds: closedItemStore.recordIdsSnapshot,
                    actions: VaultHistoryRowActions(
                        onResume: onResume,
                        onReopenClosedItem: onReopenClosedItem
                    )
                )
            }
        }
        .onAppear {
            if sessionStore.entries.isEmpty && !sessionStore.isLoading {
                sessionStore.reload()
            }
            model.refresh(sessionEntries: sessionStore.entries)
        }
        .onChange(of: sessionStore.entries) { _, entries in
            model.refresh(sessionEntries: entries)
        }
        .onChange(of: log.revision) { _, _ in
            model.refresh(sessionEntries: sessionStore.entries)
        }
    }

    private func reload() {
        sessionStore.reload()
        model.refresh(sessionEntries: sessionStore.entries)
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
