import AppKit
import CmuxFleet
import SwiftUI

struct FleetBoardPanelView: View {
    @StateObject private var store = FleetBoardStore.shared
    @State private var quickTaskTitle = ""
    @State private var isConfigSheetPresented = false

    private let columnOrder: [FleetBoardColumn] = [.queue, .running, .needsInput, .review, .done]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            if store.snapshot.selectedFleet == nil {
                emptyState
            } else {
                quickAdd
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Divider()
                board
            }
        }
        .sheet(isPresented: $isConfigSheetPresented) {
            FleetConfigSheet(store: store)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if store.snapshot.fleets.count > 1 {
                Picker("", selection: $store.selectedFleetID) {
                    ForEach(store.snapshot.fleets) { fleet in
                        Text(fleet.name).tag(Optional(fleet.id))
                    }
                }
                .labelsHidden()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.snapshot.selectedFleet?.name ?? String(localized: "fleet.board.title", defaultValue: "Fleet"))
                        .cmuxFont(.headline)
                        .lineLimit(1)
                    if let repoRoot = store.snapshot.selectedFleet?.repoRoot {
                        Text(repoRoot)
                            .cmuxFont(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if let fleet = store.snapshot.selectedFleet {
                Circle()
                    .fill(fleet.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(
                        fleet.isRunning
                        ? String(localized: "fleet.board.running", defaultValue: "Running")
                        : String(localized: "fleet.board.stopped", defaultValue: "Stopped")
                    )
                Button {
                    fleet.isRunning ? store.stopSelectedFleet() : store.startSelectedFleet()
                } label: {
                    Image(systemName: fleet.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .safeHelp(
                    fleet.isRunning
                    ? String(localized: "fleet.board.stop", defaultValue: "Stop")
                    : String(localized: "fleet.board.start", defaultValue: "Start")
                )
            }
            Button {
                isConfigSheetPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .safeHelp(String(localized: "fleet.board.configure", defaultValue: "Configure Fleet"))
        }
    }

    private var quickAdd: some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "fleet.board.addTask.placeholder", defaultValue: "Add a task..."),
                text: $quickTaskTitle
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                addQuickTask()
            }
            Button {
                addQuickTask()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .safeHelp(String(localized: "fleet.board.addTask", defaultValue: "Add Task"))
        }
    }

    private var board: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(sectionSnapshots) { section in
                    FleetBoardSectionView(section: section, actions: rowActions)
                        .equatable()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "fleet.board.empty.noFleet", defaultValue: "No Fleet configured"))
                .cmuxFont(.headline)
            Button(String(localized: "fleet.board.empty.createFleet", defaultValue: "Create Fleet")) {
                isConfigSheetPresented = true
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var rowActions: FleetBoardRowActions {
        FleetBoardRowActions(
            onOpen: { store.openTask($0) },
            onRetry: { store.retryTask($0) },
            onCancel: { store.cancelTask($0) },
            onOpenPR: { NSWorkspace.shared.open($0) },
            onCopyPRURL: { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        )
    }

    private var sectionSnapshots: [FleetBoardSectionSnapshot] {
        columnOrder.map { column in
            FleetBoardSectionSnapshot(
                column: column,
                title: title(for: column),
                rows: store.snapshot.columns[column] ?? []
            )
        }
    }

    private func addQuickTask() {
        let title = quickTaskTitle
        store.addTask(title: title)
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            quickTaskTitle = ""
        }
    }

    private func title(for column: FleetBoardColumn) -> String {
        switch column {
        case .queue:
            String(localized: "fleet.board.column.queue", defaultValue: "Queue")
        case .running:
            String(localized: "fleet.board.column.running", defaultValue: "Running")
        case .needsInput:
            String(localized: "fleet.board.column.needsInput", defaultValue: "Needs input")
        case .review:
            String(localized: "fleet.board.column.review", defaultValue: "Review")
        case .done:
            String(localized: "fleet.board.column.done", defaultValue: "Done")
        }
    }
}
