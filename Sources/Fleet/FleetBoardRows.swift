import AppKit
import CmuxFleet
import SwiftUI

struct FleetBoardRowActions {
    let onOpen: @MainActor (FleetTaskID) -> Void
    let onRetry: @MainActor (FleetTaskID) -> Void
    let onCancel: @MainActor (FleetTaskID) -> Void
    let onOpenPR: @MainActor (URL) -> Void
    let onCopyPRURL: @MainActor (URL) -> Void
}

struct FleetBoardSectionSnapshot: Equatable, Identifiable {
    let column: FleetBoardColumn
    let title: String
    let rows: [FleetBoardRowSnapshot]

    var id: FleetBoardColumn { column }
}

struct FleetBoardSectionView: View, Equatable {
    let section: FleetBoardSectionSnapshot
    let actions: FleetBoardRowActions

    static func == (lhs: FleetBoardSectionView, rhs: FleetBoardSectionView) -> Bool {
        lhs.section == rhs.section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.title)
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
                Text("\(section.rows.count)")
                    .cmuxFont(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if section.rows.isEmpty {
                Text(emptyText(for: section.column))
                    .cmuxFont(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            } else {
                ForEach(section.rows) { row in
                    FleetBoardRowView(row: row, actions: actions)
                        .equatable()
                }
            }
        }
    }

    private func emptyText(for column: FleetBoardColumn) -> String {
        switch column {
        case .queue:
            String(localized: "fleet.board.empty.queue", defaultValue: "No queued tasks")
        case .running:
            String(localized: "fleet.board.empty.running", defaultValue: "Nothing running")
        case .needsInput:
            String(localized: "fleet.board.empty.needsInput", defaultValue: "No tasks need input")
        case .review:
            String(localized: "fleet.board.empty.review", defaultValue: "No reviews waiting")
        case .done:
            String(localized: "fleet.board.empty.done", defaultValue: "No completed tasks")
        }
    }
}

struct FleetBoardRowView: View, Equatable {
    let row: FleetBoardRowSnapshot
    let actions: FleetBoardRowActions

    static func == (lhs: FleetBoardRowView, rhs: FleetBoardRowView) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .cmuxFont(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.state == .failed, let lastError = row.lastError, !lastError.isEmpty {
                        Text(lastError)
                            .cmuxFont(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    stateChip
                    if row.attempts > 1 {
                        Text(String.localizedStringWithFormat(
                            String(localized: "fleet.board.attempts", defaultValue: "x%d"),
                            row.attempts
                        ))
                        .cmuxFont(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let prURL = row.prURL, let label = row.prLabel {
                Button {
                    actions.onOpenPR(prURL)
                } label: {
                    Label(label, systemImage: "arrow.up.right.square")
                        .labelStyle(.titleAndIcon)
                        .cmuxFont(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(row.hasWorkspace ? Color.primary.opacity(0.055) : Color.primary.opacity(0.035))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if row.hasWorkspace {
                actions.onOpen(row.id)
            }
        }
        .contextMenu {
            if row.hasWorkspace {
                Button(String(localized: "fleet.board.context.open", defaultValue: "Open")) {
                    actions.onOpen(row.id)
                }
            }
            if row.canRetry {
                Button(String(localized: "fleet.board.context.retry", defaultValue: "Retry")) {
                    actions.onRetry(row.id)
                }
            }
            if row.canCancel {
                Button(String(localized: "fleet.board.context.cancel", defaultValue: "Cancel")) {
                    actions.onCancel(row.id)
                }
            }
            if let prURL = row.prURL {
                Button(String(localized: "fleet.board.context.copyPRURL", defaultValue: "Copy PR URL")) {
                    actions.onCopyPRURL(prURL)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var stateChip: some View {
        Text(stateLabel(row.state))
            .cmuxFont(.caption2)
            .foregroundStyle(stateColor(row.state))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(stateColor(row.state).opacity(0.14)))
    }

    private func stateLabel(_ state: FleetTaskState) -> String {
        switch state {
        case .queued:
            String(localized: "fleet.taskState.queued", defaultValue: "Queued")
        case .provisioning:
            String(localized: "fleet.taskState.provisioning", defaultValue: "Provisioning")
        case .launching:
            String(localized: "fleet.taskState.launching", defaultValue: "Launching")
        case .running:
            String(localized: "fleet.taskState.running", defaultValue: "Running")
        case .needsInput:
            String(localized: "fleet.taskState.needsInput", defaultValue: "Needs input")
        case .stalled:
            String(localized: "fleet.taskState.stalled", defaultValue: "Stalled")
        case .retryBackoff:
            String(localized: "fleet.taskState.retryBackoff", defaultValue: "Retrying")
        case .awaitingReview:
            String(localized: "fleet.taskState.awaitingReview", defaultValue: "Review")
        case .done:
            String(localized: "fleet.taskState.done", defaultValue: "Done")
        case .failed:
            String(localized: "fleet.taskState.failed", defaultValue: "Failed")
        case .cancelled:
            String(localized: "fleet.taskState.cancelled", defaultValue: "Cancelled")
        }
    }

    private func stateColor(_ state: FleetTaskState) -> Color {
        switch state {
        case .queued:
            .gray
        case .provisioning, .launching, .running:
            .blue
        case .needsInput, .stalled, .retryBackoff:
            .orange
        case .awaitingReview:
            .purple
        case .done:
            .green
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }
}
