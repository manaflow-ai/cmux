import SwiftUI

struct SchedulerPage: View {
    @EnvironmentObject var schedulerEngine: SchedulerEngine
    @Binding var selection: SidebarSelection

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if schedulerEngine.tasks.isEmpty {
                emptyState
            } else {
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
                                    let run = TaskRun(taskId: task.id, startedAt: Date())
                                    schedulerEngine.runs.append(run)
                                    schedulerEngine.onTaskDue?(task, run)
                                },
                                onDelete: {
                                    schedulerEngine.removeTask(id: task.id)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Scheduler")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            // Cost/token summary
            let usage = ClaudeTokenTracker.aggregateUsage()
            if usage.totalTokens > 0 {
                HStack(spacing: 6) {
                    Text(ClaudeTokenTracker.formatTokens(usage.totalTokens) + " tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(ClaudeTokenTracker.formatCost(usage.estimatedCostUSD))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !schedulerEngine.tasks.isEmpty {
                let running = schedulerEngine.runningTaskCount
                if running > 0 {
                    Text("\(running) running")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No scheduled tasks")
                .font(.headline)
            Text("Use the CLI to create scheduled tasks:\ncmux scheduler create --name \"my task\" --cron \"*/5 * * * *\" --command \"echo hello\"")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                Text(task.name)
                    .font(.headline)
                    .foregroundColor(.primary)

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

            HStack {
                Text(task.cronExpression)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                if let nextFire = task.nextFireDate(after: Date()) {
                    Text("Next: \(nextFire.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(task.command)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)

            if let run = latestRun {
                HStack(spacing: 4) {
                    Text(statusLabel(for: run.status))
                        .font(.caption)
                        .foregroundColor(statusLabelColor(for: run.status))

                    if let completedAt = run.completedAt {
                        Text(completedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let exitCode = run.exitCode, exitCode != 0 {
                        Text("(exit \(exitCode))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

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
                        .foregroundColor(.secondary)
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
