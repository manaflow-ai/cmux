import AppKit
import SwiftUI

enum GoalSupervisionStatus: String, CaseIterable, Codable, Hashable, Identifiable {
    case pending
    case active
    case paused
    case blocked
    case done
    case abandoned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pending:
            return String(localized: "goals.status.pending", defaultValue: "Pending")
        case .active:
            return String(localized: "goals.status.active", defaultValue: "Active")
        case .paused:
            return String(localized: "goals.status.paused", defaultValue: "Paused")
        case .blocked:
            return String(localized: "goals.status.blocked", defaultValue: "Blocked")
        case .done:
            return String(localized: "goals.status.done", defaultValue: "Done")
        case .abandoned:
            return String(localized: "goals.status.abandoned", defaultValue: "Abandoned")
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "circle"
        case .active: return "play.circle.fill"
        case .paused: return "pause.circle"
        case .blocked: return "exclamationmark.octagon"
        case .done: return "checkmark.circle.fill"
        case .abandoned: return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .active: return .green
        case .paused: return .orange
        case .blocked: return .red
        case .done: return .blue
        case .abandoned: return .gray
        }
    }
}

struct GoalSupervisionNote: Codable, Hashable, Identifiable {
    let id: UUID
    var body: String
    var createdAt: Date
}

struct GoalSupervisionRecord: Codable, Hashable, Identifiable {
    let id: UUID
    var title: String
    var acceptanceCriteria: String
    var workspacePath: String?
    var status: GoalSupervisionStatus
    var createdAt: Date
    var updatedAt: Date
    var activeSince: Date?
    var accumulatedActiveSeconds: TimeInterval
    var notes: [GoalSupervisionNote]

    mutating func accumulateActiveTime(endingAt date: Date) {
        guard status == .active, let activeSince else { return }
        accumulatedActiveSeconds += max(0, date.timeIntervalSince(activeSince))
        self.activeSince = nil
    }

    func activeDuration(at date: Date) -> TimeInterval {
        guard status == .active, let activeSince else {
            return accumulatedActiveSeconds
        }
        return accumulatedActiveSeconds + max(0, date.timeIntervalSince(activeSince))
    }
}

struct GoalSupervisionSnapshot: Equatable, Identifiable {
    let id: UUID
    let title: String
    let acceptanceCriteria: String
    let workspacePath: String?
    let status: GoalSupervisionStatus
    let createdAt: Date
    let updatedAt: Date
    let activeDuration: TimeInterval
    let notes: [GoalSupervisionNote]

    var wallClockDuration: TimeInterval {
        max(0, Date.now.timeIntervalSince(createdAt))
    }

    var workspaceLabel: String {
        guard let workspacePath, !workspacePath.isEmpty else {
            return String(localized: "goals.workspace.none", defaultValue: "No workspace")
        }
        let lastPathComponent = (workspacePath as NSString).lastPathComponent
        return lastPathComponent.isEmpty ? workspacePath : lastPathComponent
    }
}

@MainActor
final class GoalSupervisionStore: ObservableObject {
    static let shared = GoalSupervisionStore()

    @Published private(set) var goals: [GoalSupervisionRecord] = []
    @Published private(set) var lastError: String?

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func snapshots(at date: Date = .now) -> [GoalSupervisionSnapshot] {
        goals.map { goal in
            GoalSupervisionSnapshot(
                id: goal.id,
                title: goal.title,
                acceptanceCriteria: goal.acceptanceCriteria,
                workspacePath: goal.workspacePath,
                status: goal.status,
                createdAt: goal.createdAt,
                updatedAt: goal.updatedAt,
                activeDuration: goal.activeDuration(at: date),
                notes: goal.notes
            )
        }
    }

    func createGoal(title: String, acceptanceCriteria: String, workspacePath: String?) -> UUID? {
        let normalizedTitle = Self.normalized(title)
        guard !normalizedTitle.isEmpty else { return nil }

        let now = Date.now
        let normalizedWorkspacePath = Self.normalizedOptional(workspacePath)
        let goal = GoalSupervisionRecord(
            id: UUID(),
            title: normalizedTitle,
            acceptanceCriteria: Self.normalized(acceptanceCriteria),
            workspacePath: normalizedWorkspacePath,
            status: .active,
            createdAt: now,
            updatedAt: now,
            activeSince: now,
            accumulatedActiveSeconds: 0,
            notes: []
        )
        goals.insert(goal, at: 0)
        persist()
        return goal.id
    }

    func updateStatus(for id: UUID, status: GoalSupervisionStatus) {
        updateGoal(id: id) { goal, now in
            guard goal.status != status else { return }
            goal.accumulateActiveTime(endingAt: now)
            goal.status = status
            goal.activeSince = status == .active ? now : nil
        }
    }

    func addNote(to id: UUID, body: String) {
        let normalizedBody = Self.normalized(body)
        guard !normalizedBody.isEmpty else { return }
        updateGoal(id: id) { goal, now in
            goal.notes.insert(
                GoalSupervisionNote(id: UUID(), body: normalizedBody, createdAt: now),
                at: 0
            )
        }
    }

    func deleteGoal(id: UUID) {
        guard goals.contains(where: { $0.id == id }) else { return }
        goals.removeAll { $0.id == id }
        persist()
    }

    private func updateGoal(
        id: UUID,
        _ mutate: (inout GoalSupervisionRecord, Date) -> Void
    ) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        var goal = goals[index]
        let now = Date.now
        mutate(&goal, now)
        goal.updatedAt = now
        goals[index] = goal
        goals.sort { lhs, rhs in
            if lhs.status == .active, rhs.status != .active { return true }
            if lhs.status != .active, rhs.status == .active { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
        persist()
    }

    private func load() {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                goals = []
                return
            }
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            goals = try decoder.decode([GoalSupervisionRecord].self, from: data)
            lastError = nil
        } catch {
            goals = []
            lastError = error.localizedDescription
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(goals)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("goals.json", isDirectory: false)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

struct GoalSupervisionPanelView: View {
    let currentWorkspacePath: String?

    @StateObject private var store = GoalSupervisionStore.shared
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
                    onCancel: {
                        showingNewGoalPopover = false
                    }
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
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(snapshots) { snapshot in
                    GoalListRow(snapshot: snapshot) {
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

private struct GoalListRow: View, Equatable {
    let snapshot: GoalSupervisionSnapshot
    let onSelect: () -> Void

    static func == (lhs: GoalListRow, rhs: GoalListRow) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    StatusChip(status: snapshot.status)
                    Spacer(minLength: 0)
                    Text(Self.relativeFormatter.localizedString(for: snapshot.updatedAt, relativeTo: .now))
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

private struct GoalDetailView: View {
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
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    metrics
                    notes
                }
                .padding(12)
            }
            .modifier(ClearScrollBackground())
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

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "goals.metrics.title", defaultValue: "Metrics"))
                .font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricTile(
                    title: String(localized: "goals.metrics.wallClock", defaultValue: "Wall clock"),
                    value: Self.durationFormatter.string(from: snapshot.wallClockDuration) ?? "-"
                )
                MetricTile(
                    title: String(localized: "goals.metrics.active", defaultValue: "Active"),
                    value: Self.durationFormatter.string(from: snapshot.activeDuration) ?? "-"
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.absoluteFormatter.string(from: note.createdAt))
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

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
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

private struct StatusChip: View {
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

private struct NewGoalPopover: View {
    let currentWorkspacePath: String?
    let onCreate: (String, String, String?) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var acceptanceCriteria = ""
    @State private var usesCurrentWorkspace = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "goals.new.title", defaultValue: "New Goal"))
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "goals.field.title", defaultValue: "Title"))
                    .font(.system(size: 11, weight: .medium))
                TextField(
                    String(localized: "goals.field.title.placeholder", defaultValue: "Ship onboarding flow"),
                    text: $title
                )
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "goals.field.acceptanceCriteria", defaultValue: "Acceptance criteria"))
                    .font(.system(size: 11, weight: .medium))
                TextEditor(text: $acceptanceCriteria)
                    .font(.system(size: 12))
                    .frame(width: 300, height: 92)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
            }

            if currentWorkspacePath != nil {
                Toggle(isOn: $usesCurrentWorkspace) {
                    Text(String(localized: "goals.field.currentWorkspace", defaultValue: "Link current workspace"))
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "goals.new.cancel", defaultValue: "Cancel")) {
                    onCancel()
                }
                Button(String(localized: "goals.new.create", defaultValue: "Create")) {
                    onCreate(
                        title,
                        acceptanceCriteria,
                        usesCurrentWorkspace ? currentWorkspacePath : nil
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 328)
    }
}
