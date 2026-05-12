import SwiftUI

struct GoalDetailView: View {
    let snapshot: GoalSupervisionSnapshot
    let onBack: () -> Void
    let onStatusChange: (GoalSupervisionStatus) -> Void
    let onAddNote: (String) -> Void
    let onDelete: () -> Void

    @State private var draftNote = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            detailBar
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        metrics(now: context.date)
                        notes
                    }
                    .padding(12)
                }
                .modifier(ClearScrollBackground())
            }
        }
        .confirmationDialog(
            String(localized: "goals.delete.confirmTitle", defaultValue: "Delete Goal?"),
            isPresented: $isConfirmingDelete
        ) {
            Button(String(localized: "goals.delete.confirmAction", defaultValue: "Delete"), role: .destructive) {
                onDelete()
            }
            Button(String(localized: "goals.delete.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }

    private var detailBar: some View {
        HStack(spacing: 6) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: RightSidebarChromeMetrics.controlHeight, height: RightSidebarChromeMetrics.controlHeight)
            }
            .buttonStyle(.plain)
            .help(String(localized: "goals.back.help", defaultValue: "Back to Goals"))

            Picker(selection: Binding(
                get: { snapshot.status },
                set: { onStatusChange($0) }
            )) {
                ForEach(GoalSupervisionStatus.allCases) { status in
                    Label(status.label, systemImage: status.symbolName)
                        .tag(status)
                }
            } label: {
                Text(String(localized: "goals.status.picker", defaultValue: "Status"))
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                isConfirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: RightSidebarChromeMetrics.controlHeight, height: RightSidebarChromeMetrics.controlHeight)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help(String(localized: "goals.delete.help", defaultValue: "Delete Goal"))
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusChip(status: snapshot.status)
            Text(snapshot.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !snapshot.acceptanceCriteria.isEmpty {
                Text(snapshot.acceptanceCriteria)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Label(snapshot.workspaceLabel, systemImage: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func metrics(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "goals.metrics.title", defaultValue: "Metrics"))
                .font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricTile(
                    title: String(localized: "goals.metrics.wallClock", defaultValue: "Wall clock"),
                    value: Self.durationFormatter.string(from: snapshot.wallClockDuration(at: now)) ?? "-"
                )
                MetricTile(
                    title: String(localized: "goals.metrics.active", defaultValue: "Active"),
                    value: Self.durationFormatter.string(from: snapshot.activeDuration(at: now)) ?? "-"
                )
                MetricTile(
                    title: String(localized: "goals.metrics.notes", defaultValue: "Notes"),
                    value: NumberFormatter.localizedString(from: NSNumber(value: snapshot.notes.count), number: .decimal)
                )
                MetricTile(
                    title: String(localized: "goals.metrics.updated", defaultValue: "Updated"),
                    value: Self.relativeFormatter.localizedString(for: snapshot.updatedAt, relativeTo: .now)
                )
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "goals.notes.title", defaultValue: "Notes"))
                .font(.system(size: 12, weight: .semibold))
            TextEditor(text: $draftNote)
                .font(.system(size: 12))
                .frame(minHeight: 70)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .accessibilityLabel(String(localized: "goals.notes.editor", defaultValue: "Goal note"))
            HStack {
                Spacer(minLength: 0)
                Button {
                    onAddNote(draftNote)
                    draftNote = ""
                } label: {
                    Label(String(localized: "goals.notes.add", defaultValue: "Add Note"), systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if snapshot.notes.isEmpty {
                Text(String(localized: "goals.notes.empty", defaultValue: "No notes"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.notes) { note in
                        NoteRow(note: note)
                    }
                }
            }
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct NoteRow: View {
    let note: GoalSupervisionNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(note.body)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
