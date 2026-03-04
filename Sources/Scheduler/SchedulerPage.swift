import SwiftUI

struct SchedulerPage: View {
    @EnvironmentObject var schedulerEngine: SchedulerEngine
    @Binding var selection: SidebarSelection
    @Binding var isFormExpanded: Bool
    @State private var cachedUsage = ClaudeTokenTracker.TokenUsage()
    @State private var formMode: SchedulerFormMode? = nil
    @State private var taskToDelete: ScheduledTask? = nil
    @State private var showDeleteConfirmation: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if formMode != nil {
                formView
            } else if schedulerEngine.tasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Delete Task?",
            isPresented: $showDeleteConfirmation,
            presenting: taskToDelete
        ) { task in
            Button("Delete", role: .destructive) {
                schedulerEngine.removeTask(id: task.id)
                taskToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                taskToDelete = nil
            }
        } message: { task in
            Text("Are you sure you want to delete \"\(task.name)\"? This cannot be undone.")
        }
        .onChange(of: isFormExpanded) { _ in
            // When the parent resets isFormExpanded (e.g., panel closed),
            // clear the form so it doesn't persist across panel close/reopen.
            if !isFormExpanded {
                formMode = nil
            }
        }
        .task {
            let usage = await Task.detached(priority: .utility) {
                ClaudeTokenTracker.aggregateUsage()
            }.value
            cachedUsage = usage
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Scheduler")
                .font(.headline)

            Spacer()

            if formMode == nil, !schedulerEngine.tasks.isEmpty {
                let running = schedulerEngine.runningTaskCount
                if running > 0 {
                    Text("\(running) running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                formMode = .create
                isFormExpanded = true
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(cmuxAccentColor())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        // Extra trailing padding to clear the titlebar scheduler toggle button
        // (NSTitlebarAccessoryViewController with .trailing layout)
        .padding(.trailing, 36)
        .padding(.vertical, 10)
    }

    // MARK: - Form

    @ViewBuilder
    private var formView: some View {
        if let mode = formMode {
            SchedulerTaskForm(
                mode: mode,
                onSave: { task in
                    commit(task: task, runNow: false)
                },
                onSaveAndRun: { task in
                    commit(task: task, runNow: true)
                },
                onCancel: {
                    formMode = nil
                    isFormExpanded = false
                }
            )
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No scheduled tasks")
                .font(.headline)
            Text("Create tasks to run commands on a schedule.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Create a Task") {
                formMode = .create
                isFormExpanded = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Task List

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(schedulerEngine.tasks) { task in
                    SchedulerTaskRow(
                        task: task,
                        latestRun: latestRun(for: task.id),
                        runningRun: runningRun(for: task.id),
                        onToggle: {
                            var updated = task
                            updated.isEnabled.toggle()
                            schedulerEngine.updateTask(updated)
                        },
                        onRunNow: {
                            _ = schedulerEngine.manuallyRunTask(task)
                        },
                        onEdit: {
                            formMode = .edit(task)
                            isFormExpanded = true
                        },
                        onDelete: {
                            taskToDelete = task
                            showDeleteConfirmation = true
                        },
                        onFocusRun: { runId in
                            schedulerEngine.focusRunningTask(runId: runId)
                            selection = .tabs
                        },
                        onCancelRun: { runId in
                            schedulerEngine.cancelTask(runId: runId)
                        }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Helpers

    private func commit(task: ScheduledTask, runNow: Bool) {
        if case .edit = formMode {
            schedulerEngine.updateTask(task)
        } else {
            schedulerEngine.addTask(task)
        }
        if runNow {
            _ = schedulerEngine.manuallyRunTask(task)
        }
        formMode = nil
        isFormExpanded = false
    }

    private func latestRun(for taskId: UUID) -> TaskRun? {
        schedulerEngine.runs
            .filter { $0.taskId == taskId }
            .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
            .first
    }

    private func runningRun(for taskId: UUID) -> TaskRun? {
        schedulerEngine.runs.first { $0.taskId == taskId && $0.status == .running }
    }
}

// MARK: - Task Row

private struct SchedulerTaskRow: View {
    let task: ScheduledTask
    let latestRun: TaskRun?
    let runningRun: TaskRun?
    let onToggle: () -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onFocusRun: (UUID) -> Void
    let onCancelRun: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(verbatim: task.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                // Enable/disable toggle
                Toggle("", isOn: Binding(
                    get: { task.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }

            // Clickable detail area for editing
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: task.cronExpression)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if let nextFire = task.nextFireDate(after: Date()) {
                            Text("Next: \(nextFire.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(verbatim: task.command)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let run = latestRun {
                        HStack(spacing: 4) {
                            Text(statusLabel(for: run.status))
                                .font(.caption)
                                .foregroundStyle(statusLabelColor(for: run.status))

                            if let completedAt = run.completedAt {
                                Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let exitCode = run.exitCode, exitCode != 0 {
                                Text("(exit \(exitCode))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Action buttons
            HStack(spacing: 8) {
                if let running = runningRun {
                    Button("Focus") {
                        onFocusRun(running.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Cancel") {
                        onCancelRun(running.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Run Now") {
                        onRunNow()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!task.isEnabled)
                }

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var statusColor: Color {
        if runningRun != nil {
            return cmuxAccentColor()
        }
        guard task.isEnabled else {
            return Color.secondary.opacity(0.4)
        }
        if let run = latestRun {
            switch run.status {
            case .succeeded: return .green
            case .failed: return .red
            case .cancelled: return .orange
            case .running: return cmuxAccentColor()
            }
        }
        return Color.secondary.opacity(0.4)
    }

    private func statusLabel(for status: TaskRunStatus) -> String {
        switch status {
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func statusLabelColor(for status: TaskRunStatus) -> Color {
        switch status {
        case .running: return cmuxAccentColor()
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}
