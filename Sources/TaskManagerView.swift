import Observation
import SwiftUI

struct CmuxTaskManagerView: View {
    @Bindable var model: CmuxTaskManagerModel

    var body: some View {
        // Outer view observes the model so the toolbar/summary/sort
        // header repaint on snapshot or sort changes. The lazy list
        // subtree is intentionally isolated below this boundary: it
        // receives value-typed snapshots and a closure action bundle so
        // row body re-evaluation can't be triggered by orthogonal model
        // mutations. See repo/CLAUDE.md "Snapshot boundary for list
        // subtrees" rule and issues #2586 / #4529.
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()
            tableHeader
            Divider()
            CmuxTaskManagerListView(
                errorMessage: model.errorMessage,
                isInitialLoading: model.isInitialLoading,
                rows: model.sortedRows,
                agentRows: model.sortedAgentRows,
                aggregateRows: model.sortedAggregateRows,
                childMemoryRows: model.sortedChildMemoryRows,
                actions: CmuxTaskManagerRowActions.bound(to: model)
            )
        }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(String(localized: "taskManager.title", defaultValue: "Task Manager"))
                .font(.title3.weight(.semibold))

            if model.isRefreshing || model.isInitialLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "taskManager.refreshing", defaultValue: "Refreshing"))
            }

            Spacer()

            Toggle(
                String(localized: "taskManager.showProcesses", defaultValue: "Processes"),
                isOn: $model.includesProcesses
            )
            .toggleStyle(.checkbox)

            Button {
                model.refresh(force: true)
            } label: {
                Label(String(localized: "taskManager.refresh", defaultValue: "Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            metric(
                title: String(localized: "taskManager.summary.cpu", defaultValue: "CPU"),
                value: CmuxTaskManagerFormat.cpu(model.snapshot.total.cpuPercent)
            )
            metric(
                title: String(localized: "taskManager.summary.memory", defaultValue: "Memory"),
                value: CmuxTaskManagerFormat.bytes(model.snapshot.total.memoryBytes)
            )
            if let memoryDiagnostic = model.snapshot.memoryDiagnostic {
                metric(
                    title: String(localized: "taskManager.summary.appFootprint", defaultValue: "App Footprint"),
                    value: CmuxTaskManagerFormat.bytes(memoryDiagnostic.appFootprintBytes)
                )
                metric(
                    title: String(localized: "taskManager.summary.childRSS", defaultValue: "Child RSS"),
                    value: CmuxTaskManagerFormat.bytes(memoryDiagnostic.childRSSBytes)
                )
            }
            metric(
                title: String(localized: "taskManager.summary.processes", defaultValue: "Processes"),
                value: "\(model.snapshot.total.processCount)"
            )
            metric(
                title: String(localized: "taskManager.summary.updated", defaultValue: "Updated"),
                value: model.snapshot.updatedText
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .monospacedDigit()
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            sortHeader(
                title: String(localized: "taskManager.column.name", defaultValue: "Name"),
                column: .name,
                maxWidth: .infinity,
                alignment: .leading
            )
            sortHeader(
                title: String(localized: "taskManager.column.cpu", defaultValue: "CPU"),
                column: .cpu,
                width: 82,
                alignment: .trailing
            )
            sortHeader(
                title: String(localized: "taskManager.column.memory", defaultValue: "Memory"),
                column: .memory,
                width: 96,
                alignment: .trailing
            )
            sortHeader(
                title: String(localized: "taskManager.column.processes", defaultValue: "Proc"),
                column: .processes,
                width: 70,
                alignment: .trailing
            )
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func sortHeader(
        title: String,
        column: CmuxTaskManagerSortOrder.Column,
        width: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        alignment: Alignment
    ) -> some View {
        Button {
            model.sort(by: column)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)
                sortIndicator(for: column)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.sortOrder.column == column ? .primary : .secondary)
        .frame(width: width, alignment: alignment)
        .frame(maxWidth: maxWidth, alignment: alignment)
        .accessibilityLabel(title)
    }

    private func sortIndicator(for column: CmuxTaskManagerSortOrder.Column) -> some View {
        let isActive = model.sortOrder.column == column
        let imageName = model.sortOrder.direction == .ascending ? "chevron.up" : "chevron.down"
        return Image(systemName: imageName)
            .font(.system(size: 8, weight: .bold))
            .opacity(isActive ? 1 : 0)
            .frame(width: 8)
            .accessibilityHidden(true)
    }
}

/// Closure bundle handed down to row views so they never reference the
/// `@Observable` `CmuxTaskManagerModel`. Matches the
/// `IndexSectionActions` / `SectionGapActions` reference pattern in
/// `Sources/SessionIndexView.swift`. See repo/CLAUDE.md
/// "Snapshot boundary for list subtrees" rule and issues #2586 / #4529.
struct CmuxTaskManagerRowActions {
    let viewWorkspace: @MainActor (CmuxTaskManagerRow) -> Void
    let viewTerminal: @MainActor (CmuxTaskManagerRow) -> Void
    let killProcess: @MainActor (CmuxTaskManagerRow) -> Void
    let activate: @MainActor (CmuxTaskManagerRow) -> Void

    @MainActor
    static func bound(to model: CmuxTaskManagerModel) -> CmuxTaskManagerRowActions {
        CmuxTaskManagerRowActions(
            viewWorkspace: { row in model.viewWorkspace(for: row) },
            viewTerminal: { row in model.viewTerminal(for: row) },
            killProcess: { row in model.killProcess(for: row) },
            activate: { row in model.viewBestTarget(for: row) }
        )
    }
}

/// Lazy list subtree. Receives value-typed row arrays plus a closure
/// action bundle so SwiftUI can prove rows never observe the
/// `CmuxTaskManagerModel`. Combined with the `Equatable` conformance on
/// `CmuxTaskManagerRowView`, this stops the 3 s refresh timer from
/// invalidating every row on every tick.
struct CmuxTaskManagerListView: View {
    let errorMessage: String?
    let isInitialLoading: Bool
    let rows: [CmuxTaskManagerRow]
    let agentRows: [CmuxTaskManagerRow]
    let aggregateRows: [CmuxTaskManagerRow]
    let childMemoryRows: [CmuxTaskManagerRow]
    let actions: CmuxTaskManagerRowActions

    var body: some View {
        if let errorMessage {
            CmuxTaskManagerMessageView(
                title: String(localized: "taskManager.error.title", defaultValue: "Unable to load resource usage"),
                detail: errorMessage
            )
        } else if isInitialLoading {
            CmuxTaskManagerLoadingView()
        } else if rows.isEmpty && agentRows.isEmpty && aggregateRows.isEmpty && childMemoryRows.isEmpty {
            CmuxTaskManagerMessageView(
                title: String(localized: "taskManager.empty.title", defaultValue: "No resource usage"),
                detail: String(localized: "taskManager.empty.detail", defaultValue: "Open a workspace, terminal, or browser surface to see it here.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !agentRows.isEmpty {
                        CmuxTaskManagerSectionHeaderView(
                            title: String(localized: "taskManager.section.codingAgents", defaultValue: "Coding Agents")
                        ).equatable()
                        ForEach(agentRows) { row in
                            CmuxTaskManagerRowView(
                                row: row,
                                onViewWorkspace: {},
                                onViewTerminal: {},
                                onKillProcess: { actions.killProcess(row) },
                                onActivate: {}
                            ).equatable()
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                    if !aggregateRows.isEmpty {
                        CmuxTaskManagerSectionHeaderView(
                            title: String(localized: "taskManager.section.programTotals", defaultValue: "Program Totals")
                        ).equatable()
                        ForEach(aggregateRows) { row in
                            CmuxTaskManagerRowView(
                                row: row,
                                onViewWorkspace: {},
                                onViewTerminal: {},
                                onKillProcess: { actions.killProcess(row) },
                                onActivate: {}
                            ).equatable()
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                    if !childMemoryRows.isEmpty {
                        CmuxTaskManagerSectionHeaderView(
                            title: String(localized: "taskManager.section.childProcessRSS", defaultValue: "Child Process RSS")
                        ).equatable()
                        ForEach(childMemoryRows) { row in
                            CmuxTaskManagerRowView(
                                row: row,
                                onViewWorkspace: { actions.viewWorkspace(row) },
                                onViewTerminal: { actions.viewTerminal(row) },
                                onKillProcess: { actions.killProcess(row) },
                                onActivate: { actions.activate(row) }
                            ).equatable()
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                    if !rows.isEmpty && (!agentRows.isEmpty || !aggregateRows.isEmpty || !childMemoryRows.isEmpty) {
                        CmuxTaskManagerSectionHeaderView(
                            title: String(localized: "taskManager.section.hierarchy", defaultValue: "Hierarchy")
                        ).equatable()
                    }
                    ForEach(rows) { row in
                        CmuxTaskManagerRowView(
                            row: row,
                            onViewWorkspace: { actions.viewWorkspace(row) },
                            onViewTerminal: { actions.viewTerminal(row) },
                            onKillProcess: { actions.killProcess(row) },
                            onActivate: { actions.activate(row) }
                        ).equatable()
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }
}

private struct CmuxTaskManagerSectionHeaderView: View, Equatable {
    let title: String

    static func == (lhs: CmuxTaskManagerSectionHeaderView, rhs: CmuxTaskManagerSectionHeaderView) -> Bool {
        lhs.title == rhs.title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

private struct CmuxTaskManagerLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel(String(localized: "taskManager.loading.title", defaultValue: "Loading resource usage"))
            Text(String(localized: "taskManager.loading.title", defaultValue: "Loading resource usage"))
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct CmuxTaskManagerMessageView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Row view rendered inside the lazy list subtree. Conforms to
/// `Equatable` so SwiftUI can skip body re-evaluation when the `row`
/// snapshot is unchanged, even if the parent rebuilt the closure
/// bundle on a refresh tick. Closures are intentionally excluded from
/// `==`; they're expected to be stable in semantics (capture the same
/// model above the snapshot boundary) but their identity changes every
/// render. Comparing closure identity would defeat the optimization
/// and re-introduce the 0.64.8 memory leak (issue #4529).
struct CmuxTaskManagerRowView: View, Equatable {
    let row: CmuxTaskManagerRow
    let onViewWorkspace: @MainActor () -> Void
    let onViewTerminal: @MainActor () -> Void
    let onKillProcess: @MainActor () -> Void
    let onActivate: @MainActor () -> Void

    static func == (lhs: CmuxTaskManagerRowView, rhs: CmuxTaskManagerRowView) -> Bool {
        // Closures excluded on purpose: the parent rebuilds the action
        // bundle on every render tick, but the row payload is what
        // actually drives visible state. Comparing closure identity
        // would defeat `.equatable()` at the ForEach call site and
        // re-introduce the 0.64.8 memory leak.
        lhs.row == rhs.row
    }

    var body: some View {
        Group {
            if row.canViewWorkspace || row.canViewTerminal {
                Button(action: onActivate) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .contextMenu {
            if row.canViewWorkspace {
                Button {
                    onViewWorkspace()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.viewWorkspace", defaultValue: "View Workspace"),
                        systemImage: "rectangle.stack"
                    )
                }
            }
            if row.canViewTerminal {
                Button {
                    onViewTerminal()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.viewTerminal", defaultValue: "View Terminal"),
                        systemImage: "terminal"
                    )
                }
            }
            if row.canKillProcess {
                if row.canViewWorkspace || row.canViewTerminal {
                    Divider()
                }
                Button {
                    onKillProcess()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.killProcess", defaultValue: "Kill Process..."),
                        systemImage: "xmark.octagon"
                    )
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Color.clear
                    .frame(width: CGFloat(row.level) * 14)
                rowIcon
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(CmuxTaskManagerFormat.cpu(row.resources.cpuPercent))
                .frame(width: 82, alignment: .trailing)
            Text(CmuxTaskManagerFormat.bytes(row.resources.memoryBytes))
                .frame(width: 96, alignment: .trailing)
            Text("\(row.resources.processCount)")
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12.5, design: .default))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .opacity(row.isDimmed ? 0.68 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowIcon: some View {
        if let agentAssetName = row.agentAssetName {
            Image(agentAssetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: row.kind.systemImage)
                .foregroundStyle(row.kind.tint)
                .font(.system(size: 12))
                .frame(width: 14)
        }
    }
}
