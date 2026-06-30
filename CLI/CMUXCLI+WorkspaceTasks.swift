import Foundation

extension CMUXCLI {
    func runWorkspaceTasksCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased(),
              subcommand != "--help",
              subcommand != "-h" else {
            print(workspaceTasksUsage())
            return
        }
        if subcommand == "help" {
            print(workspaceTasksUsage())
            return
        }

        let rest = Array(commandArgs.dropFirst())
        switch subcommand {
        case "list":
            try runWorkspaceTasksListCommand(
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        case "add":
            try runWorkspaceTasksAddCommand(
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        case "archive", "complete":
            try runWorkspaceTasksTaskMutationCommand(
                commandName: "workspace tasks \(subcommand)",
                method: "workspace.tasks.archive",
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        case "unarchive", "restore":
            try runWorkspaceTasksTaskMutationCommand(
                commandName: "workspace tasks \(subcommand)",
                method: "workspace.tasks.unarchive",
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        case "remove", "delete", "rm":
            try runWorkspaceTasksTaskMutationCommand(
                commandName: "workspace tasks \(subcommand)",
                method: "workspace.tasks.remove",
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        case "move", "reorder":
            try runWorkspaceTasksMoveCommand(
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        case "open":
            try runWorkspaceTasksOpenCommand(
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        default:
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspaceTasks.error.unknownSubcommand",
                    defaultValue: "Unknown workspace tasks subcommand: %@. Try: list, add, archive, unarchive, remove, move, open"
                ),
                locale: .current,
                subcommand
            ))
        }
    }

    private func runWorkspaceTasksListCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        try validateWorkspaceTasksRequiredOptionValues(
            commandArgs,
            commandName: "workspace tasks list",
            valueFlags: ["--workspace", "--window"]
        )
        let (workspaceArg, rem0) = parseOption(commandArgs, name: "--workspace")
        let (_, rem1) = parseOption(rem0, name: "--window")
        try rejectUnknownWorkspaceTasksFlags(rem1, commandName: "workspace tasks list", knownFlags: ["--workspace", "--window"])
        let positionals = positionalArguments(rem1)
        guard positionals.count <= (workspaceArg == nil ? 1 : 0) else {
            throw CLIError(message: String(localized: "cli.workspaceTasks.list.error.tooManyArguments", defaultValue: "workspace tasks list accepts at most one workspace handle"))
        }
        let params = try workspaceTasksTargetParams(
            commandArgs: commandArgs,
            positionalWorkspace: workspaceArg ?? positionals.first,
            client: client,
            windowOverride: windowOverride
        )
        let payload = try client.sendV2(method: "workspace.tasks.list", params: params)
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: workspaceTasksListSummary(payload, idFormat: idFormat)
        )
    }

    private func runWorkspaceTasksAddCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        try validateWorkspaceTasksRequiredOptionValues(
            commandArgs,
            commandName: "workspace tasks add",
            valueFlags: ["--title", "--before", "--after", "--index", "--workspace", "--window"]
        )
        let (titleOpt, rem0) = parseOption(commandArgs, name: "--title")
        let (beforeOpt, rem1) = parseOption(rem0, name: "--before")
        let (afterOpt, rem2) = parseOption(rem1, name: "--after")
        let (indexOpt, rem3) = parseOption(rem2, name: "--index")
        let (_, rem4) = parseOption(rem3, name: "--workspace")
        let (_, rem5) = parseOption(rem4, name: "--window")
        try rejectUnknownWorkspaceTasksFlags(
            rem5,
            commandName: "workspace tasks add",
            knownFlags: ["--title", "--before", "--after", "--index", "--workspace", "--window"]
        )

        let titleArguments = positionalArguments(rem5)
        if titleOpt != nil, !titleArguments.isEmpty {
            throw CLIError(message: String(localized: "cli.workspaceTasks.add.error.unexpectedArguments", defaultValue: "workspace tasks add cannot combine --title with positional title arguments"))
        }
        let title = (titleOpt ?? titleArguments.joined(separator: " "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw CLIError(message: String(localized: "cli.workspaceTasks.add.error.titleRequired", defaultValue: "workspace tasks add requires --title <text> or a title argument"))
        }
        guard title.count <= Self.workspaceTaskTitleCharacterLimit else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspaceTasks.add.error.titleTooLong",
                    defaultValue: "workspace tasks add title must be %d characters or fewer"
                ),
                locale: .current,
                Self.workspaceTaskTitleCharacterLimit
            ))
        }

        var params = try workspaceTasksTargetParams(
            commandArgs: commandArgs,
            positionalWorkspace: nil,
            client: client,
            windowOverride: windowOverride
        )
        params["title"] = title
        try applyWorkspaceTaskPlacement(
            before: beforeOpt,
            after: afterOpt,
            index: indexOpt,
            to: &params,
            commandName: "workspace tasks add"
        )

        let payload = try client.sendV2(method: "workspace.tasks.add", params: params)
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: workspaceTasksMutationSummary(payload, idFormat: idFormat)
        )
    }

    private func runWorkspaceTasksTaskMutationCommand(
        commandName: String,
        method: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        try validateWorkspaceTasksRequiredOptionValues(
            commandArgs,
            commandName: commandName,
            valueFlags: ["--task", "--task-id", "--id", "--workspace", "--window"]
        )
        let (taskOpt, rem0) = parseOption(commandArgs, name: "--task")
        let (taskIdOpt, rem1) = parseOption(rem0, name: "--task-id")
        let (idOpt, rem2) = parseOption(rem1, name: "--id")
        let (_, rem3) = parseOption(rem2, name: "--workspace")
        let (_, rem4) = parseOption(rem3, name: "--window")
        try rejectUnknownWorkspaceTasksFlags(
            rem4,
            commandName: commandName,
            knownFlags: ["--task", "--task-id", "--id", "--workspace", "--window"]
        )
        let positionals = positionalArguments(rem4)
        let taskId = taskOpt ?? taskIdOpt ?? idOpt ?? positionals.first
        guard let taskId, UUID(uuidString: taskId) != nil else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspaceTasks.error.taskIdRequired",
                    defaultValue: "%@ requires a task UUID"
                ),
                locale: .current,
                commandName
            ))
        }
        guard positionals.count <= (taskOpt == nil && taskIdOpt == nil && idOpt == nil ? 1 : 0) else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspaceTasks.error.unexpectedArguments",
                    defaultValue: "%@ has unexpected positional arguments"
                ),
                locale: .current,
                commandName
            ))
        }

        var params = try workspaceTasksTargetParams(
            commandArgs: commandArgs,
            positionalWorkspace: nil,
            client: client,
            windowOverride: windowOverride
        )
        params["task_id"] = taskId
        let payload = try client.sendV2(method: method, params: params)
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: workspaceTasksMutationSummary(payload, idFormat: idFormat)
        )
    }

    private func runWorkspaceTasksMoveCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        try validateWorkspaceTasksRequiredOptionValues(
            commandArgs,
            commandName: "workspace tasks move",
            valueFlags: ["--task", "--task-id", "--id", "--before", "--after", "--index", "--workspace", "--window"]
        )
        let (taskOpt, rem0) = parseOption(commandArgs, name: "--task")
        let (taskIdOpt, rem1) = parseOption(rem0, name: "--task-id")
        let (idOpt, rem2) = parseOption(rem1, name: "--id")
        let (beforeOpt, rem3) = parseOption(rem2, name: "--before")
        let (afterOpt, rem4) = parseOption(rem3, name: "--after")
        let (indexOpt, rem5) = parseOption(rem4, name: "--index")
        let (_, rem6) = parseOption(rem5, name: "--workspace")
        let (_, rem7) = parseOption(rem6, name: "--window")
        try rejectUnknownWorkspaceTasksFlags(
            rem7,
            commandName: "workspace tasks move",
            knownFlags: ["--task", "--task-id", "--id", "--before", "--after", "--index", "--workspace", "--window"]
        )
        let positionals = positionalArguments(rem7)
        let taskId = taskOpt ?? taskIdOpt ?? idOpt ?? positionals.first
        guard let taskId, UUID(uuidString: taskId) != nil else {
            throw CLIError(message: String(localized: "cli.workspaceTasks.move.error.taskIdRequired", defaultValue: "workspace tasks move requires a task UUID"))
        }
        guard positionals.count <= (taskOpt == nil && taskIdOpt == nil && idOpt == nil ? 1 : 0) else {
            throw CLIError(message: String(localized: "cli.workspaceTasks.move.error.unexpectedArguments", defaultValue: "workspace tasks move has unexpected positional arguments"))
        }

        var params = try workspaceTasksTargetParams(
            commandArgs: commandArgs,
            positionalWorkspace: nil,
            client: client,
            windowOverride: windowOverride
        )
        params["task_id"] = taskId
        try applyWorkspaceTaskPlacement(
            before: beforeOpt,
            after: afterOpt,
            index: indexOpt,
            to: &params,
            commandName: "workspace tasks move",
            requiresPlacement: true
        )
        let payload = try client.sendV2(method: "workspace.tasks.move", params: params)
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: workspaceTasksMutationSummary(payload, idFormat: idFormat)
        )
    }

    private func runWorkspaceTasksOpenCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        try validateWorkspaceTasksRequiredOptionValues(
            commandArgs,
            commandName: "workspace tasks open",
            valueFlags: ["--workspace", "--window", "--focus"]
        )
        let (workspaceArg, rem0) = parseOption(commandArgs, name: "--workspace")
        let (_, rem1) = parseOption(rem0, name: "--window")
        let (focusOpt, rem2) = parseOption(rem1, name: "--focus")
        try rejectUnknownWorkspaceTasksFlags(rem2, commandName: "workspace tasks open", knownFlags: ["--workspace", "--window", "--focus"])
        let positionals = positionalArguments(rem2)
        guard positionals.count <= (workspaceArg == nil ? 1 : 0) else {
            throw CLIError(message: String(localized: "cli.workspaceTasks.open.error.tooManyArguments", defaultValue: "workspace tasks open accepts at most one workspace handle"))
        }
        let focus: Bool
        if let focusOpt {
            guard let parsed = parseBoolString(focusOpt.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CLIError(message: String(localized: "cli.workspaceTasks.open.error.invalidFocus", defaultValue: "workspace tasks open: --focus must be true or false"))
            }
            focus = parsed
        } else {
            focus = false
        }

        var params = try workspaceTasksTargetParams(
            commandArgs: commandArgs,
            positionalWorkspace: workspaceArg ?? positionals.first,
            client: client,
            windowOverride: windowOverride
        )
        params["focus"] = focus
        let payload = try client.sendV2(method: "workspace.tasks.open", params: params)
        let fallback = workspaceTasksOpenSummary(payload, idFormat: idFormat)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: fallback)
    }

    private func workspaceTasksTargetParams(
        commandArgs: [String],
        positionalWorkspace: String?,
        client: SocketClient,
        windowOverride: String?
    ) throws -> [String: Any] {
        let windowRaw = windowFromArgsOrOverride(commandArgs, windowOverride: windowOverride)
        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
            ?? positionalWorkspace
            ?? (windowRaw == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        var params: [String: Any] = [:]
        let windowId = try normalizeWindowHandle(windowRaw, client: client)
        if let windowId {
            params["window_id"] = windowId
        }
        if let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowId) {
            let workspaceId = isUUID(workspaceHandle)
                ? workspaceHandle
                : try resolveWorkspaceId(workspaceHandle, client: client, windowHandle: windowId)
            params["workspace_id"] = workspaceId
        }
        return params
    }

    func validateWorkspaceTasksRequiredOptionValues(
        _ args: [String],
        commandName: String,
        valueFlags: Set<String>
    ) throws {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                return
            }
            guard arg.hasPrefix("--") else {
                index += 1
                continue
            }

            let flag = String(arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            guard valueFlags.contains(flag) else {
                index += 1
                continue
            }

            if arg.hasPrefix("\(flag)=") {
                let value = String(arg.dropFirst(flag.count + 1))
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    index += 1
                    continue
                }
            } else if index + 1 < args.count {
                let value = args[index + 1]
                if value != "--",
                   !value.hasPrefix("--"),
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    index += 2
                    continue
                }
            }

            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspaceTasks.error.flagRequiresValue",
                    defaultValue: "%@: %@ requires a value"
                ),
                locale: .current,
                commandName,
                flag
            ))
        }
    }

    private func applyWorkspaceTaskPlacement(
        before: String?,
        after: String?,
        index: String?,
        to params: inout [String: Any],
        commandName: String,
        requiresPlacement: Bool = false
    ) throws {
        let placementCount = [before, after, index].filter { $0 != nil }.count
        if requiresPlacement, placementCount == 0 {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspaceTasks.error.placementRequired",
                    defaultValue: "%@ requires --before, --after, or --index"
                ),
                locale: .current,
                commandName
            ))
        }
        guard placementCount <= 1 else {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspaceTasks.error.onePlacement",
                    defaultValue: "%@ accepts only one of --before, --after, or --index"
                ),
                locale: .current,
                commandName
            ))
        }
        if let before {
            guard UUID(uuidString: before) != nil else {
                throw CLIError(message: String(localized: "cli.workspaceTasks.error.invalidBefore", defaultValue: "--before requires a task UUID"))
            }
            params["before_task_id"] = before
        }
        if let after {
            guard UUID(uuidString: after) != nil else {
                throw CLIError(message: String(localized: "cli.workspaceTasks.error.invalidAfter", defaultValue: "--after requires a task UUID"))
            }
            params["after_task_id"] = after
        }
        if let index {
            guard let parsed = Int(index), parsed >= 0 else {
                throw CLIError(message: String(localized: "cli.workspaceTasks.error.invalidIndex", defaultValue: "--index requires a non-negative integer"))
            }
            params["index"] = parsed
        }
    }

    func rejectUnknownWorkspaceTasksFlags(
        _ args: [String],
        commandName: String,
        knownFlags: Set<String>
    ) throws {
        if let unknown = args.first(where: { arg in
            arg.hasPrefix("--") && arg != "--" && !knownFlags.contains(String(arg.split(separator: "=", maxSplits: 1).first ?? ""))
        }) {
            throw CLIError(message: String(
                format: String(
                    localized: "cli.workspaceTasks.error.unknownFlag",
                    defaultValue: "%@: unknown flag '%@'"
                ),
                locale: .current,
                commandName,
                unknown
            ))
        }
    }

    func positionalArguments(_ args: [String]) -> [String] {
        args.filter { arg in
            arg != "--" && !arg.hasPrefix("--")
        }
    }

    private func workspaceTasksListSummary(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let workspace = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown"
        let openTasks = payload["open"] as? [[String: Any]] ?? []
        let archivedTasks = payload["archived"] as? [[String: Any]] ?? []
        if openTasks.isEmpty, archivedTasks.isEmpty {
            return String(
                format: String(localized: "cli.workspaceTasks.list.empty", defaultValue: "No workspace tasks for %@"),
                locale: .current,
                workspace
            )
        }
        var lines = [
            String(
                format: String(localized: "cli.workspaceTasks.list.header", defaultValue: "Workspace %@"),
                locale: .current,
                workspace
            ),
            String(localized: "cli.workspaceTasks.list.openHeader", defaultValue: "Open:")
        ]
        lines.append(contentsOf: workspaceTaskLines(openTasks))
        lines.append(String(localized: "cli.workspaceTasks.list.archivedHeader", defaultValue: "Archived:"))
        lines.append(contentsOf: workspaceTaskLines(archivedTasks))
        return lines.joined(separator: "\n")
    }

    private func workspaceTaskLines(_ tasks: [[String: Any]]) -> [String] {
        guard !tasks.isEmpty else {
            return ["  " + String(localized: "cli.workspaceTasks.list.none", defaultValue: "(none)")]
        }
        return tasks.map { task in
            let id = task["id"] as? String ?? "unknown"
            let title = task["title"] as? String ?? ""
            return "  \(id)  \(title)"
        }
    }

    private func workspaceTasksMutationSummary(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let workspace = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown"
        let task = payload["task"] as? [String: Any]
        let taskId = task?["id"] as? String ?? "unknown"
        return String(
            format: String(localized: "cli.workspaceTasks.mutation.ok", defaultValue: "OK task=%@ workspace=%@"),
            locale: .current,
            taskId,
            workspace
        )
    }

    private func workspaceTasksOpenSummary(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        let workspace = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? "unknown"
        let surface = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
        return String(
            format: String(localized: "cli.workspaceTasks.open.ok", defaultValue: "OK surface=%@ workspace=%@"),
            locale: .current,
            surface,
            workspace
        )
    }

}
