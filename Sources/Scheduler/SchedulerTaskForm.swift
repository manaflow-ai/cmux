import SwiftUI

// MARK: - FormMode

enum SchedulerFormMode: Equatable {
    case create
    case edit(ScheduledTask)
}

// MARK: - CronPreset

enum CronPreset: String, CaseIterable, Identifiable {
    case everyMinute = "Every minute"
    case every5Minutes = "Every 5 minutes"
    case every15Minutes = "Every 15 minutes"
    case hourly = "Hourly"
    case dailyAtMidnight = "Daily at midnight"
    case weekdaysAt9AM = "Weekdays at 9 AM"
    case custom = "Custom"

    var id: String { rawValue }

    var expression: String? {
        switch self {
        case .everyMinute: return "*/1 * * * *"
        case .every5Minutes: return "*/5 * * * *"
        case .every15Minutes: return "*/15 * * * *"
        case .hourly: return "0 * * * *"
        case .dailyAtMidnight: return "0 0 * * *"
        case .weekdaysAt9AM: return "0 9 * * 1-5"
        case .custom: return nil
        }
    }

    static func preset(for expression: String) -> CronPreset {
        for preset in allCases where preset != .custom {
            if preset.expression == expression { return preset }
        }
        return .custom
    }
}

// MARK: - SchedulerTaskForm

struct SchedulerTaskForm: View {
    let mode: SchedulerFormMode
    let onSave: (ScheduledTask) -> Void
    let onSaveAndRun: (ScheduledTask) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var cronText: String = "*/5 * * * *"
    @State private var selectedPreset: CronPreset = .every5Minutes
    @State private var command: String = ""
    @State private var workingDirectory: String = ""

    // Advanced
    @State private var showAdvanced: Bool = false
    @State private var allowOverlap: Bool = false
    @State private var worktreeOption: WorktreeOption = .defaultOption
    @State private var onSuccessTaskName: String = ""
    @State private var onFailureTaskName: String = ""
    @State private var envRows: [EnvRow] = []

    // Validation
    @State private var nextFireDates: [Date] = []

    // Preserved for edit mode
    private var editingTaskId: UUID?
    private var editingCreatedAt: Date?

    init(
        mode: SchedulerFormMode,
        onSave: @escaping (ScheduledTask) -> Void,
        onSaveAndRun: @escaping (ScheduledTask) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onSaveAndRun = onSaveAndRun
        self.onCancel = onCancel

        if case .edit(let task) = mode {
            self.editingTaskId = task.id
            self.editingCreatedAt = task.createdAt
        }
    }

    private var isFormValid: Bool {
        !name.isEmpty && !command.isEmpty && CronExpression(cronText) != nil
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title
                Text(isEditMode ? "Edit Task" : "New Task")
                    .font(.headline)

                // Name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Task name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                // Cron
                CronInputSection(
                    selectedPreset: $selectedPreset,
                    cronText: $cronText,
                    nextFireDates: nextFireDates
                )

                // Command
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("e.g. echo hello", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                // Working directory
                VStack(alignment: .leading, spacing: 4) {
                    Text("Working Directory")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Optional", text: $workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                // Advanced section
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Allow overlap", isOn: $allowOverlap)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Worktree isolation")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $worktreeOption) {
                                ForEach(WorktreeOption.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("On success task")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("Task name to chain", text: $onSuccessTaskName)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("On failure task")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("Task name to chain", text: $onFailureTaskName)
                                .textFieldStyle(.roundedBorder)
                        }

                        EnvironmentEditor(rows: $envRows)
                    }
                    .padding(.top, 8)
                }

                Divider()

                // Footer buttons
                HStack {
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(isEditMode ? "Save & Run" : "Create & Run Now") {
                        onSaveAndRun(buildTask())
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isFormValid)

                    Button(isEditMode ? "Save" : "Create") {
                        onSave(buildTask())
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isFormValid)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if case .edit(let task) = mode {
                prefill(from: task)
            }
            updateNextFireDates()
        }
        .onChange(of: cronText) { _ in
            updateNextFireDates()
        }
        .onChange(of: selectedPreset) { _ in
            if let expr = selectedPreset.expression {
                cronText = expr
            }
        }
    }

    // MARK: - Helpers

    private func prefill(from task: ScheduledTask) {
        name = task.name
        cronText = task.cronExpression
        selectedPreset = CronPreset.preset(for: task.cronExpression)
        command = task.command
        workingDirectory = task.workingDirectory ?? ""
        allowOverlap = task.allowOverlap
        worktreeOption = WorktreeOption.from(task.useWorktree)
        onSuccessTaskName = task.onSuccess ?? ""
        onFailureTaskName = task.onFailure ?? ""

        if let env = task.environment {
            envRows = env.map { EnvRow(key: $0.key, value: $0.value) }
        }

        if task.onSuccess != nil || task.onFailure != nil
            || task.allowOverlap || task.useWorktree != nil
            || (task.environment?.isEmpty == false)
        {
            showAdvanced = true
        }
    }

    private func updateNextFireDates() {
        guard let cron = CronExpression(cronText) else {
            nextFireDates = []
            return
        }
        var dates: [Date] = []
        var reference = Date()
        let twoYearsFromNow = Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? Date()
        for _ in 0..<3 {
            guard let next = cron.nextFireDate(after: reference),
                  next <= twoYearsFromNow else { break }
            dates.append(next)
            reference = next
        }
        nextFireDates = dates
    }

    private func buildTask() -> ScheduledTask {
        let env: [String: String]? = envRows.isEmpty ? nil : Dictionary(
            uniqueKeysWithValues: envRows
                .filter { !$0.key.isEmpty }
                .map { ($0.key, $0.value) }
        )

        return ScheduledTask(
            id: editingTaskId ?? UUID(),
            name: name,
            cronExpression: cronText,
            command: command,
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            environment: env,
            isEnabled: true,
            allowOverlap: allowOverlap,
            useWorktree: worktreeOption.toBool,
            onSuccess: onSuccessTaskName.isEmpty ? nil : onSuccessTaskName,
            onFailure: onFailureTaskName.isEmpty ? nil : onFailureTaskName,
            createdAt: editingCreatedAt ?? Date()
        )
    }
}

// MARK: - WorktreeOption

enum WorktreeOption: String, CaseIterable, Identifiable {
    case defaultOption = "Default"
    case always = "Always"
    case never = "Never"

    var id: String { rawValue }
    var label: String { rawValue }

    var toBool: Bool? {
        switch self {
        case .defaultOption: return nil
        case .always: return true
        case .never: return false
        }
    }

    static func from(_ value: Bool?) -> WorktreeOption {
        switch value {
        case .none: return .defaultOption
        case .some(true): return .always
        case .some(false): return .never
        }
    }
}

// MARK: - CronInputSection

private struct CronInputSection: View {
    @Binding var selectedPreset: CronPreset
    @Binding var cronText: String
    let nextFireDates: [Date]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Schedule")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Preset", selection: $selectedPreset) {
                ForEach(CronPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .labelsHidden()

            TextField("Cron expression", text: $cronText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onChange(of: cronText) { _ in
                    selectedPreset = CronPreset.preset(for: cronText)
                }

            if CronExpression(cronText) == nil && !cronText.isEmpty {
                Text("Invalid expression")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !nextFireDates.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next runs:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(nextFireDates, id: \.self) { date in
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - EnvRow

struct EnvRow: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

// MARK: - EnvironmentEditor

private struct EnvironmentEditor: View {
    @Binding var rows: [EnvRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Environment Variables")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    rows.append(EnvRow())
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            ForEach($rows) { $row in
                HStack(spacing: 4) {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("=")
                        .foregroundStyle(.secondary)
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
