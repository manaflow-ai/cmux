import AppKit
import SwiftUI

struct GoalSupervisionPanelView: View {
    let currentWorkspacePath: String?
    private let store = GoalSupervisionStore.shared

    @State private var selectedGoalID: UUID?
    @State private var showingNewGoalPopover = false

    private var snapshots: [GoalSupervisionSnapshot] {
        store.snapshots()
    }

    private var selectedGoal: GoalSupervisionSnapshot? {
        guard let selectedGoalID else { return nil }
        return snapshots.first { $0.id == selectedGoalID }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            if let error = store.lastError {
                errorBanner(error)
            }
            content
        }
        .onChange(of: store.goals) { _, _ in
            guard let selectedGoalID else { return }
            if !store.goals.contains(where: { $0.id == selectedGoalID }) {
                self.selectedGoalID = nil
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            Text(String(localized: "goals.title", defaultValue: "Goals"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Button {
                showingNewGoalPopover = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: RightSidebarChromeMetrics.controlHeight, height: RightSidebarChromeMetrics.controlHeight)
            }
            .buttonStyle(.plain)
            .help(String(localized: "goals.new.help", defaultValue: "New Goal"))
            .accessibilityLabel(String(localized: "goals.new.accessibilityLabel", defaultValue: "New Goal"))
            .popover(isPresented: $showingNewGoalPopover, arrowEdge: .bottom) {
                NewGoalPopover(
                    currentWorkspacePath: currentWorkspacePath,
                    onCreate: { title, criteria, workspacePath in
                        if let id = store.createGoal(
                            title: title,
                            acceptanceCriteria: criteria,
                            workspacePath: workspacePath
                        ) {
                            selectedGoalID = id
                            showingNewGoalPopover = false
                        }
                    },
                    onCancel: { showingNewGoalPopover = false }
                )
            }
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder()
        .accessibilityIdentifier("Goals.controlBar")
    }

    @ViewBuilder
    private var content: some View {
        if snapshots.isEmpty {
            GoalEmptyView {
                showingNewGoalPopover = true
            }
        } else if let selectedGoal {
            GoalDetailView(
                snapshot: selectedGoal,
                onBack: { selectedGoalID = nil },
                onStatusChange: { status in
                    store.updateStatus(for: selectedGoal.id, status: status)
                },
                onAddNote: { note in
                    store.addNote(to: selectedGoal.id, body: note)
                },
                onDelete: {
                    store.deleteGoal(id: selectedGoal.id)
                    selectedGoalID = nil
                }
            )
            .id(selectedGoal.id)
        } else {
            GoalListView(
                snapshots: snapshots,
                onSelect: { selectedGoalID = $0 }
            )
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(error)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
    }
}

private struct GoalEmptyView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "target")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(String(localized: "goals.empty.title", defaultValue: "No goals yet"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Button {
                onCreate()
            } label: {
                Label(String(localized: "goals.empty.new", defaultValue: "New Goal"), systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GoalListView: View {
    let snapshots: [GoalSupervisionSnapshot]
    let onSelect: (UUID) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(snapshots) { snapshot in
                        GoalListRow(snapshot: snapshot, relativeTo: context.date) {
                            onSelect(snapshot.id)
                        }
                        .equatable()
                    }
                }
                .padding(.vertical, 6)
            }
            .modifier(ClearScrollBackground())
        }
    }
}

private struct GoalListRow: View, Equatable {
    let snapshot: GoalSupervisionSnapshot
    let relativeTo: Date
    let onSelect: () -> Void

    static func == (lhs: GoalListRow, rhs: GoalListRow) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.relativeTo == rhs.relativeTo
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    StatusChip(status: snapshot.status)
                    Spacer(minLength: 0)
                    Text(Self.relativeFormatter.localizedString(for: snapshot.updatedAt, relativeTo: relativeTo))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(snapshot.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(snapshot.workspaceLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Goals.row.\(snapshot.id.uuidString)")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct StatusChip: View {
    let status: GoalSupervisionStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbolName)
                .font(.system(size: 10, weight: .semibold))
            Text(status.label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(status.tint.opacity(0.12))
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}

private extension GoalSupervisionStatus {
    var tint: Color {
        switch self {
        case .pending: .secondary
        case .active: .green
        case .paused: .orange
        case .blocked: .red
        case .done: .blue
        case .abandoned: .gray
        }
    }
}
