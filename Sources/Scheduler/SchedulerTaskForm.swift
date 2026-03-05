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

// MARK: - TaskTypeMode

enum TaskTypeMode: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case general = "General"
    var id: String { rawValue }
}

// MARK: - ClaudeModel

enum ClaudeModel: String, CaseIterable, Identifiable {
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// MARK: - ClaudePermissionMode

enum ClaudePermissionMode: String, CaseIterable, Identifiable {
    case plan = "plan"
    case autoEdit = "acceptEdits"
    case fullAuto = "bypass"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plan: return "Plan (safe)"
        case .autoEdit: return "Auto-approve"
        case .fullAuto: return "Unrestricted"
        }
    }

    var cliFlag: String {
        switch self {
        case .plan: return "--permission-mode plan"
        case .autoEdit: return "--permission-mode acceptEdits"
        case .fullAuto: return "--dangerously-skip-permissions"
        }
    }
}

// MARK: - ClaudeToolPreset

enum ClaudeToolPreset: String, CaseIterable, Identifiable {
    case readOnly = "Read-only"
    case standard = "Standard"
    case full = "Full"
    case custom = "Custom"

    var id: String { rawValue }

    var tools: Set<String>? {
        switch self {
        case .readOnly: return ["Read", "Glob", "Grep", "WebSearch"]
        case .standard: return ["Read", "Glob", "Grep", "Edit", "Bash", "Write", "WebSearch"]
        case .full: return nil
        case .custom: return nil
        }
    }
}

// MARK: - ClaudeTool

struct ClaudeTool: Identifiable, Hashable {
    let name: String
    var id: String { name }

    static let all: [ClaudeTool] = [
        "Read", "Edit", "Write", "Bash", "Glob", "Grep",
        "WebSearch", "WebFetch", "Agent", "Notebook",
    ].map { ClaudeTool(name: $0) }
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

    // Task type
    @State private var taskType: TaskTypeMode = .claude

    // Claude fields
    @State private var claudeModel: ClaudeModel = .sonnet
    @State private var claudePrompt: String = ""
    @State private var claudeProject: String = ""
    @State private var claudePermission: ClaudePermissionMode = .fullAuto
    @State private var claudeMaxTurns: String = ""
    @State private var claudeMaxBudget: String = ""
    @State private var claudeToolPreset: ClaudeToolPreset = .standard
    @State private var claudeCustomTools: Set<String> = ["Read", "Glob", "Grep", "WebSearch"]
    @State private var showPermissionConfirmation: Bool = false
    @State private var pendingPermissionAction: (() -> Void)?

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

                // Task type toggle
                Picker("", selection: $taskType) {
                    ForEach(TaskTypeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

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

                if taskType == .claude {
                    ClaudeFieldsSection(
                        claudeModel: $claudeModel,
                        claudePrompt: $claudePrompt,
                        claudeProject: $claudeProject,
                        claudePermission: $claudePermission,
                        claudeMaxTurns: $claudeMaxTurns,
                        claudeMaxBudget: $claudeMaxBudget
                    )
                } else {
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
                }

                // Advanced section
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        if taskType == .claude {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Allowed tools")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $claudeToolPreset) {
                                    ForEach(ClaudeToolPreset.allCases) { preset in
                                        Text(preset.rawValue).tag(preset)
                                    }
                                }
                                .labelsHidden()

                                if claudeToolPreset == .custom {
                                    LazyVGrid(
                                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                                        spacing: 4
                                    ) {
                                        ForEach(ClaudeTool.all) { tool in
                                            Toggle(tool.name, isOn: Binding(
                                                get: { claudeCustomTools.contains(tool.name) },
                                                set: { enabled in
                                                    if enabled {
                                                        claudeCustomTools.insert(tool.name)
                                                    } else {
                                                        claudeCustomTools.remove(tool.name)
                                                    }
                                                }
                                            ))
                                            .toggleStyle(.checkbox)
                                        }
                                    }
                                }
                            }
                        }

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

                // Command preview (Claude mode)
                if taskType == .claude {
                    DisclosureGroup("Generated command") {
                        Text(generatedClaudeCommandPreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
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
                        confirmIfNeeded { onSaveAndRun(buildTask()) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isFormValid)

                    Button(isEditMode ? "Save" : "Create") {
                        confirmIfNeeded { onSave(buildTask()) }
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
        .alert(
            "Unrestricted Mode",
            isPresented: $showPermissionConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                pendingPermissionAction = nil
            }
            Button("Continue", role: .destructive) {
                pendingPermissionAction?()
                pendingPermissionAction = nil
            }
        } message: {
            Text(
                "Unrestricted mode disables all permission prompts. "
                + "Claude will be able to read, write, and execute files without asking. Continue?"
            )
        }
    }

    // MARK: - Validation

    private enum Limits {
        static let maxPromptLength = 32_000
        static let maxPathLength = 4_096
        static let maxTurns = 200
        static let maxBudgetUSD = 100.0
    }

    private var isFormValid: Bool {
        let validCron = CronExpression(cronText) != nil
        if taskType == .claude {
            return !name.isEmpty
                && !claudePrompt.isEmpty
                && claudePrompt.count <= Limits.maxPromptLength
                && validCron
        } else {
            return !name.isEmpty && !command.isEmpty && validCron
        }
    }

    // MARK: - Shell Escaping

    private func shellEscape(_ s: String) -> String {
        // Replace newlines with spaces — initial_input delivers characters as
        // keyboard input, so literal newlines act as Enter keypresses and split
        // the command. Newlines in prompts are just whitespace for Claude.
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return "'" + flat.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Claude Command Generation

    private static let knownToolNames: Set<String> = Set(ClaudeTool.all.map(\.name))

    /// Build the argument list for a claude -p (print/headless) command.
    /// Print mode is required for scheduled tasks: it skips the workspace trust
    /// dialog and runs non-interactively.
    private var claudeCommandParts: [String] {
        // Per Claude CLI docs, the prompt is the argument to -p:
        //   claude -p "prompt here" --allowedTools "Read,Edit,Bash"
        var parts = ["claude", "-p", shellEscape(claudePrompt)]
        parts.append(contentsOf: ["--model", claudeModel.rawValue])
        parts.append(claudePermission.cliFlag)

        if let turns = Int(claudeMaxTurns), turns > 0, turns <= Limits.maxTurns {
            parts.append(contentsOf: ["--max-turns", "\(turns)"])
        }
        if let budget = Double(claudeMaxBudget), budget > 0, budget <= Limits.maxBudgetUSD {
            parts.append(contentsOf: ["--max-budget-usd", String(format: "%.2f", budget)])
        }

        // --allowedTools is ignored when combined with --dangerously-skip-permissions
        // (known CLI behavior). Only emit it for plan and acceptEdits modes.
        if claudePermission != .fullAuto {
            let toolsList: String? = {
                switch claudeToolPreset {
                case .readOnly, .standard:
                    return claudeToolPreset.tools?.sorted().joined(separator: ",")
                case .full:
                    return nil
                case .custom:
                    let safe = claudeCustomTools.filter { Self.knownToolNames.contains($0) }
                    return safe.isEmpty ? nil : safe.sorted().joined(separator: ",")
                }
            }()
            if let tools = toolsList {
                parts.append(contentsOf: ["--allowedTools", shellEscape(tools)])
            }
        }

        return parts
    }

    /// Single-line command string for execution via shell.
    private var generatedClaudeCommand: String {
        claudeCommandParts.joined(separator: " ")
    }

    /// Multi-line display string for the preview panel.
    private var generatedClaudeCommandPreview: String {
        claudeCommandParts.joined(separator: " \\\n  ")
    }

    // MARK: - Permission Confirmation

    private func confirmIfNeeded(_ action: @escaping () -> Void) {
        if taskType == .claude && claudePermission == .fullAuto {
            pendingPermissionAction = action
            showPermissionConfirmation = true
        } else {
            action()
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

        // Detect Claude mode from existing command
        if task.command.hasPrefix("claude ") {
            taskType = .claude
            parseClaudeCommand(task.command)
            claudeProject = task.workingDirectory ?? ""
        } else {
            taskType = .general
        }
    }

    private func parseClaudeCommand(_ cmd: String) {
        // Extract --model <value>
        if let range = cmd.range(of: #"--model\s+(\w+)"#, options: .regularExpression) {
            let modelStr = String(cmd[range]).replacingOccurrences(
                of: "--model ", with: ""
            ).trimmingCharacters(in: .whitespaces)
            if let model = ClaudeModel.allCases.first(where: { $0.rawValue == modelStr }) {
                claudeModel = model
            }
        }

        // Extract permission mode
        if cmd.contains("--dangerously-skip-permissions") {
            claudePermission = .fullAuto
        } else if let range = cmd.range(
            of: #"--permission-mode\s+([\w-]+)"#, options: .regularExpression
        ) {
            let modeStr = String(cmd[range]).replacingOccurrences(
                of: "--permission-mode ", with: ""
            ).trimmingCharacters(in: .whitespaces)
            if let perm = ClaudePermissionMode.allCases.first(where: { $0.rawValue == modeStr }) {
                claudePermission = perm
            }
        }

        // Extract --max-turns <value>
        if let range = cmd.range(of: #"--max-turns\s+(\d+)"#, options: .regularExpression) {
            let turnsStr = String(cmd[range]).replacingOccurrences(
                of: "--max-turns ", with: ""
            ).trimmingCharacters(in: .whitespaces)
            claudeMaxTurns = turnsStr
        }

        // Extract --max-budget-usd <value>
        if let range = cmd.range(
            of: #"--max-budget-usd\s+([\d.]+)"#, options: .regularExpression
        ) {
            let budgetStr = String(cmd[range]).replacingOccurrences(
                of: "--max-budget-usd ", with: ""
            ).trimmingCharacters(in: .whitespaces)
            claudeMaxBudget = budgetStr
        }

        // Extract --allowedTools '<csv>'
        if let range = cmd.range(
            of: #"--allowedTools\s+'([^']+)'"#, options: .regularExpression
        ) {
            let toolsMatch = String(cmd[range])
            // Extract content between single quotes
            if let qStart = toolsMatch.firstIndex(of: "'"),
               let qEnd = toolsMatch[toolsMatch.index(after: qStart)...].firstIndex(of: "'")
            {
                let csv = String(toolsMatch[toolsMatch.index(after: qStart)..<qEnd])
                let tools = Set(csv.split(separator: ",").map { String($0) })
                let validTools = tools.filter { Self.knownToolNames.contains($0) }

                // Match against presets
                if validTools == ClaudeToolPreset.readOnly.tools {
                    claudeToolPreset = .readOnly
                } else if validTools == ClaudeToolPreset.standard.tools {
                    claudeToolPreset = .standard
                } else {
                    claudeToolPreset = .custom
                    claudeCustomTools = validTools
                }
            }
        } else if !cmd.contains("--allowedTools") {
            claudeToolPreset = .full
        }

        // Extract the prompt — last single-quoted string
        // Walk backwards to find the last top-level single-quoted segment
        let stripped = cmd.replacingOccurrences(of: " \\\n  ", with: " ")
        if let lastQuote = stripped.lastIndex(of: "'") {
            let before = stripped[..<lastQuote]
            // Find the matching opening quote (not preceded by \)
            var depth = 0
            var openIndex: String.Index?
            var i = before.startIndex
            while i < before.endIndex {
                if before[i] == "'" {
                    if depth == 0 {
                        // Check this isn't inside the --allowedTools arg
                        let prefix = String(before[..<i])
                        if !prefix.hasSuffix("--allowedTools ") {
                            openIndex = i
                        }
                    }
                    depth = depth == 0 ? 1 : 0
                }
                i = before.index(after: i)
            }
            if let open = openIndex {
                let quoted = String(stripped[stripped.index(after: open)...lastQuote])
                // Remove trailing quote
                let prompt = String(quoted.dropLast())
                    .replacingOccurrences(of: "'\\''", with: "'")
                claudePrompt = prompt
            }
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

        let finalCommand: String
        let finalWorkingDir: String?

        if taskType == .claude {
            finalCommand = generatedClaudeCommand
            if !claudeProject.isEmpty {
                let path = claudeProject.hasPrefix("~")
                    ? NSString(string: claudeProject).expandingTildeInPath
                    : claudeProject
                // Only accept absolute paths
                finalWorkingDir = path.hasPrefix("/") ? path : nil
            } else {
                finalWorkingDir = nil
            }
        } else {
            finalCommand = command
            finalWorkingDir = workingDirectory.isEmpty ? nil : workingDirectory
        }

        return ScheduledTask(
            id: editingTaskId ?? UUID(),
            name: name,
            cronExpression: cronText,
            command: finalCommand,
            workingDirectory: finalWorkingDir,
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

// MARK: - ClaudeFieldsSection

private struct ClaudeFieldsSection: View {
    @Binding var claudeModel: ClaudeModel
    @Binding var claudePrompt: String
    @Binding var claudeProject: String
    @Binding var claudePermission: ClaudePermissionMode
    @Binding var claudeMaxTurns: String
    @Binding var claudeMaxBudget: String

    var body: some View {
        // Model
        VStack(alignment: .leading, spacing: 4) {
            Text("Model")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $claudeModel) {
                ForEach(ClaudeModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Project directory
        VStack(alignment: .leading, spacing: 4) {
            Text("Project Directory")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("~/code/myproject", text: $claudeProject)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }

        // Permission mode
        VStack(alignment: .leading, spacing: 4) {
            Text("Permission Mode")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $claudePermission) {
                ForEach(ClaudePermissionMode.allCases) { perm in
                    Text(perm.displayName).tag(perm)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        // Prompt
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: $claudePrompt)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .frame(minHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.secondary.opacity(0.3))
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }

        // Cost controls
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Max turns")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("unlimited", text: $claudeMaxTurns)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Max budget")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("unlimited", text: $claudeMaxBudget)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
    }
}
