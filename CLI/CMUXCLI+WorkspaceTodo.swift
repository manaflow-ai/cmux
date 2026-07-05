import Foundation

/// `cmux workspace status [...]` and the `cmux todo` namespace: the CLI face
/// of the `workspace.status.*` / `workspace.todo.*` socket verbs. Both default
/// to the caller's workspace (CMUX_WORKSPACE_ID, the same ambient resolution
/// `workspace env` uses) with `--workspace <id|ref|index>` override.
extension CMUXCLI {
    // MARK: - Shared target resolution

    /// Resolves the `--workspace` / `--window` flags (plus the ambient
    /// caller-workspace default) shared by every status/todo subcommand.
    private func workspaceTodoTarget(
        _ commandArgs: [String],
        client: SocketClient,
        windowOverride: String?
    ) throws -> (params: [String: Any], rest: [String]) {
        let (workspaceArg, rem0) = parseOption(commandArgs, name: "--workspace")
        let (windowArg, rem1) = parseOption(rem0, name: "--window")
        var params: [String: Any] = [:]
        let winId = try normalizeWindowHandle(windowArg ?? windowOverride, client: client)
        if let winId { params["window_id"] = winId }
        if let wsId = try normalizeWorkspaceHandle(
            workspaceArg,
            client: client,
            windowHandle: winId,
            allowCurrent: true
        ) {
            params["workspace_id"] = wsId
        }
        let rest = rem1.filter { $0 != "--json" }
        return (params, rest)
    }

    /// Parses a checklist item selector: a UUID id, or a 1-based index as
    /// printed by `cmux todo list` (sent as the wire's 0-based `index`).
    private func workspaceTodoItemSelectorParams(_ raw: String) throws -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil {
            return ["id": trimmed]
        }
        if let number = Int(trimmed), number >= 1 {
            return ["index": number - 1]
        }
        throw CLIError(message: "Invalid todo item: \(trimmed) (expected an item UUID or a 1-based index from `cmux todo list`)")
    }

    // MARK: - workspace status

    /// `cmux workspace status` / `cmux workspace status set <lane|auto>`.
    func runWorkspaceStatusCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.workspaceStatusUsage)
            return
        }
        let (params, rest) = try workspaceTodoTarget(
            commandArgs, client: client, windowOverride: windowOverride
        )
        switch rest.first?.lowercased() {
        case nil:
            let payload = try client.sendV2(method: "workspace.status.get", params: params)
            printWorkspaceStatusPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "set":
            guard rest.count >= 2 else {
                throw CLIError(message: "Usage: cmux workspace status set <todo|working|needs-attention|review|done|auto>")
            }
            var setParams = params
            setParams["status"] = rest[1]
            let payload = try client.sendV2(method: "workspace.status.set", params: setParams)
            printWorkspaceStatusPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "cycle":
            let payload = try client.sendV2(method: "workspace.status.cycle", params: params)
            printWorkspaceStatusPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case .some(let sub):
            throw CLIError(message: "Unknown workspace status subcommand: \(sub). Try: cmux workspace status [set <lane|auto> | cycle]")
        }
    }

    private func printWorkspaceStatusPayload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        let effective = payload["effective"] as? String ?? "todo"
        let inferred = payload["inferred"] as? String ?? "todo"
        let overrideLine: String
        if let override = payload["override"] as? [String: Any],
           let status = override["status"] as? String {
            overrideLine = "override: \(status) (auto-clears when inferred moves off \(override["inferred_at_override"] as? String ?? inferred))"
        } else {
            overrideLine = "override: none (auto)"
        }
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: "\(effective)\ninferred: \(inferred)\n\(overrideLine)"
        )
    }

    // MARK: - todo namespace

    /// Top-level `cmux todo <subcommand>` namespace.
    func runTodoNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.todoUsage)
            return
        }
        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: "todo requires a subcommand. Try: add, list, check, uncheck, start, edit, rm, move, clear, set, open")
        }
        let (params, rest) = try workspaceTodoTarget(
            Array(commandArgs.dropFirst()), client: client, windowOverride: windowOverride
        )
        switch sub {
        case "list", "ls":
            let payload = try client.sendV2(method: "workspace.todo.list", params: params)
            printTodoListPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "add":
            var addParams = params
            let (stateArg, rem0) = parseOption(rest, name: "--state")
            let (originArg, rem1) = parseOption(rem0, name: "--origin")
            let text = rem1.filter { !$0.hasPrefix("--") }.joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: "Usage: cmux todo add \"text\" [--state <pending|in-progress|completed>] [--origin <user|agent>]")
            }
            addParams["text"] = text
            if let stateArg { addParams["state"] = stateArg }
            if let originArg { addParams["origin"] = originArg }
            let payload = try client.sendV2(method: "workspace.todo.add", params: addParams)
            printTodoMutationPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "check", "uncheck", "start":
            guard let selector = rest.first(where: { !$0.hasPrefix("--") }) else {
                throw CLIError(message: "Usage: cmux todo \(sub) <index|id>")
            }
            var stateParams = params
            for (key, value) in try workspaceTodoItemSelectorParams(selector) {
                stateParams[key] = value
            }
            stateParams["state"] = ["check": "completed", "uncheck": "pending", "start": "in-progress"][sub]
            let payload = try client.sendV2(method: "workspace.todo.set_state", params: stateParams)
            printTodoMutationPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "edit":
            let positional = rest.filter { !$0.hasPrefix("--") }
            guard positional.count >= 2 else {
                throw CLIError(message: "Usage: cmux todo edit <index|id> \"new text\"")
            }
            var editParams = params
            for (key, value) in try workspaceTodoItemSelectorParams(positional[0]) {
                editParams[key] = value
            }
            editParams["text"] = positional.dropFirst().joined(separator: " ")
            let payload = try client.sendV2(method: "workspace.todo.edit", params: editParams)
            printTodoMutationPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "rm", "remove":
            guard let selector = rest.first(where: { !$0.hasPrefix("--") }) else {
                throw CLIError(message: "Usage: cmux todo rm <index|id>")
            }
            var removeParams = params
            for (key, value) in try workspaceTodoItemSelectorParams(selector) {
                removeParams[key] = value
            }
            let payload = try client.sendV2(method: "workspace.todo.remove", params: removeParams)
            printTodoMutationPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "move", "mv":
            let positional = rest.filter { !$0.hasPrefix("--") }
            guard positional.count >= 2, let newIndex = Int(positional[1]), newIndex >= 1 else {
                throw CLIError(message: "Usage: cmux todo move <index|id> <newIndex> (newIndex is 1-based)")
            }
            var moveParams = params
            for (key, value) in try workspaceTodoItemSelectorParams(positional[0]) {
                moveParams[key] = value
            }
            moveParams["to_index"] = newIndex - 1
            let payload = try client.sendV2(method: "workspace.todo.move", params: moveParams)
            printTodoMutationPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "clear":
            let payload = try client.sendV2(method: "workspace.todo.clear", params: params)
            printTodoMutationPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "set":
            var setParams = params
            setParams["items"] = try workspaceTodoSetItemsArgument(rest: rest)
            let payload = try client.sendV2(method: "workspace.todo.set", params: setParams)
            printTodoListPayload(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "open":
            let payload = try client.sendV2(method: "workspace.todo.open", params: params)
            printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK")
        default:
            throw CLIError(message: "Unknown todo subcommand: \(sub). Try: add, list, check, uncheck, start, edit, rm, move, clear, set, open")
        }
    }

    /// Parses `cmux todo set`'s items JSON: an inline positional argument, or
    /// stdin when no argument is given (`--json` is the CLI's global
    /// JSON-output flag, so the payload cannot ride on it). Accepts a
    /// top-level array of item objects, or an object with an `items` array.
    /// Ids are optional; items are addressed by identity only, never index.
    private func workspaceTodoSetItemsArgument(rest: [String]) throws -> [[String: Any]] {
        let raw: String
        if let inline = rest.first(where: { !$0.hasPrefix("--") }) {
            raw = inline
        } else {
            var data = Data()
            while let line = readLine(strippingNewline: false) {
                data.append(Data(line.utf8))
            }
            raw = String(data: data, encoding: .utf8) ?? ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Usage: cmux todo set '[{\"text\":\"...\",\"state\":\"pending\"}]' (or pipe the JSON on stdin)")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            throw CLIError(message: "Invalid JSON for todo set: \(error.localizedDescription)")
        }
        if let items = parsed as? [[String: Any]] {
            return items
        }
        if let object = parsed as? [String: Any], let items = object["items"] as? [[String: Any]] {
            return items
        }
        throw CLIError(message: "todo set expects a JSON array of {text, state?, id?, origin?} objects (or {\"items\": [...]})")
    }

    // MARK: - todo output

    private func printTodoListPayload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let items = payload["items"] as? [[String: Any]] ?? []
        guard !items.isEmpty else {
            print("No todo items.")
            return
        }
        for (index, item) in items.enumerated() {
            let state = item["state"] as? String ?? "pending"
            let marker = state == "completed" ? "[x]" : (state == "in-progress" ? "[>]" : "[ ]")
            let origin = (item["origin"] as? String) == "agent" ? "  (agent)" : ""
            print("\(index + 1). \(marker) \(item["text"] as? String ?? "")\(origin)")
        }
        if let progress = payload["progress"] as? [String: Any],
           let completed = intFromAny(progress["completed"]),
           let total = intFromAny(progress["total"]) {
            print("\(completed)/\(total) completed")
        }
    }

    private func printTodoMutationPayload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        var summary = "OK"
        if let progress = payload["progress"] as? [String: Any],
           let completed = intFromAny(progress["completed"]),
           let total = intFromAny(progress["total"]) {
            summary = "OK (\(completed)/\(total) completed)"
        }
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    // MARK: - Usage

    static let workspaceStatusUsage = """
    Usage: cmux workspace status [set <lane|auto> | cycle] [--workspace <id|ref|index>] [--window <id|ref|index>] [--json]

    Show or pin a workspace's todo lifecycle status. Without arguments prints
    the effective status, the inferred status, and the override, targeting the
    caller's workspace by default.

    Lanes are inferred from live signals (agent needs input > agent running >
    open PR > all PRs merged/closed > dirty git tree > todo). `set <lane>`
    pins a manual lane that auto-clears as soon as the inferred lane changes;
    `set auto` clears the pin immediately. `cycle` advances the manual override
    one lane forward (todo → working → needs-attention → review → done → todo).

    Lanes: todo, working, needs-attention, review, done

    Examples:
      cmux workspace status
      cmux workspace status set review
      cmux workspace status cycle
      cmux workspace status set auto --workspace workspace:2
    """

    static let todoUsage = """
    Usage: cmux todo <subcommand> [--workspace <id|ref|index>] [--window <id|ref|index>] [--json]

    Per-workspace checklist, writable by you and by agents. Targets the
    caller's workspace by default. Items are capped at 50 per workspace.

    Subcommands:
      add "text" [--state <pending|in-progress|completed>] [--origin <user|agent>]
      list                    Print items (1-based indexes) and progress
      check <index|id>        Mark an item completed
      uncheck <index|id>      Mark an item pending
      start <index|id>        Mark an item in-progress
      edit <index|id> "text"  Rewrite an item's text
      rm <index|id>           Remove an item
      clear                   Remove every item
      set ['<json>']          Atomically replace the whole checklist from a
                              JSON array of {text, state?, id?, origin?}
                              objects (inline argument, or piped on stdin).
                              Items whose id matches an existing item keep
                              their identity and origin; the rest are created
                              and unnamed existing items are removed.
      open                    Open (or focus) the workspace's todo pane

    <index> is the 1-based number printed by `cmux todo list`; <id> is the
    item UUID from `cmux todo list --json`.

    Examples:
      cmux todo add "write regression test"
      cmux todo list
      cmux todo check 1
      cmux todo start 2 --workspace workspace:3
      my-plan-tool --json | cmux todo set
      cmux todo open

    See also: cmux workspace status
    """
}
