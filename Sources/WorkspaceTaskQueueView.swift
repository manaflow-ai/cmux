import CmuxControlSocket
import SwiftUI

/// Queue window content. The list subtree receives immutable snapshots and
/// closures so refreshes do not make every row observe the model.
struct WorkspaceTaskQueueView: View {
    @Bindable var model: WorkspaceTaskQueueModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty {
                ContentUnavailableView(
                    String(localized: "taskQueue.empty.title", defaultValue: "No queued tasks"),
                    systemImage: "checklist",
                    description: Text(String(localized: "taskQueue.empty.detail", defaultValue: "Tasks from every workspace appear here."))
                )
            } else {
                WorkspaceTaskQueueListView(
                    rows: model.rows,
                    selectedRowID: model.selectedRowID,
                    onSelect: { row in model.reveal(row) },
                    onDispatch: { row in model.dispatch(row) },
                    onReveal: { row in model.reveal(row) }
                )
            }
        }
        .frame(minWidth: 860, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: .workspaceTaskQueueDidChange)) { _ in
            model.scheduleRefresh()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(String(localized: "taskQueue.title", defaultValue: "Task Queue"))
                .font(.title3.weight(.semibold))
            Picker(String(localized: "taskQueue.filter.status", defaultValue: "Status"), selection: $model.statusFilter) {
                ForEach(WorkspaceTaskQueueModel.StatusFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            Picker(String(localized: "taskQueue.filter.workspace", defaultValue: "Workspace"), selection: $model.workspaceFilter) {
                Text(String(localized: "taskQueue.filter.workspace.all", defaultValue: "All workspaces")).tag(Optional<UUID>.none)
                ForEach(model.workspaceOptions, id: \.id) { option in
                    Text(option.title).tag(Optional(option.id))
                }
            }
            .labelsHidden()
            Picker(String(localized: "taskQueue.sort", defaultValue: "Sort"), selection: $model.sortKey) {
                ForEach(WorkspaceTaskQueueModel.SortKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            .labelsHidden()
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Button {
                model.refresh()
            } label: {
                Label(String(localized: "taskQueue.refresh", defaultValue: "Refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct WorkspaceTaskQueueListView: View {
    let rows: [ControlWorkspaceTaskQueueItem]
    let selectedRowID: UUID?
    let onSelect: @MainActor (ControlWorkspaceTaskQueueItem) -> Void
    let onDispatch: @MainActor (ControlWorkspaceTaskQueueItem) -> Void
    let onReveal: @MainActor (ControlWorkspaceTaskQueueItem) -> Void

    var body: some View {
        List(rows, id: \.id) { row in
            WorkspaceTaskQueueRowView(
                row: row,
                isSelected: row.id == selectedRowID,
                onSelect: { onSelect(row) },
                onDispatch: { onDispatch(row) },
                onReveal: { onReveal(row) }
            )
        }
        .listStyle(.inset)
    }
}

private struct WorkspaceTaskQueueRowView: View {
    let row: ControlWorkspaceTaskQueueItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onDispatch: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                Image(systemName: symbol(for: row.state))
                    .foregroundStyle(color(for: row.state))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.text).lineLimit(2)
                HStack(spacing: 6) {
                    Text(row.workspaceTitle).foregroundStyle(.secondary)
                    if let agent = row.owningAgent {
                        Text(agent).foregroundStyle(.tertiary)
                    }
                    if let date = row.lastActivityAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if row.boundWorkspaceID != nil, row.boundWorkspaceTitle != nil {
                Label(String(localized: "taskQueue.bound", defaultValue: "Running"), systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if row.targetAgentCommand != nil {
                Button(String(localized: "taskQueue.dispatch", defaultValue: "Dispatch"), action: onDispatch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button(String(localized: "taskQueue.reveal", defaultValue: "Reveal"), action: onReveal)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func symbol(for state: String) -> String {
        switch state {
        case "completed": "checkmark.circle.fill"
        case "in-progress": "circle.lefthalf.filled"
        default: "circle"
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "completed": .green
        case "in-progress": .accentColor
        default: .secondary
        }
    }
}
