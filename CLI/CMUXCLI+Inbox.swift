import Foundation

extension CMUXCLI {
    static let integrationsUsage = String(localized: "cli.integrations.usage", defaultValue: """
    Usage: cmux integrations <list|status|connect|disconnect|sync> [args]

    Commands:
      list                                      List integration accounts and status
      status                                    Show connector status
      connect <gmail|slack|discord|imessage>   Record an account and optional token
      disconnect <source> [account]             Disconnect an account and remove its token
      sync <source|all>                         Run connector sync

    Token input:
      --token-env <NAME>   Read the token from an environment variable
      --token-stdin        Read the token from standard input
    """)

    static let inboxUsage = String(localized: "cli.inbox.usage", defaultValue: """
    Usage: cmux inbox <list|search|mark-read|draft|send|push> [args]

    Commands:
      list [--source <source>] [--unread|--actionable] [--limit N]
      search <query> [--limit N]
      mark-read <item-id|thread-id> [--thread|--item] [--unread]
      draft <thread-id> [instruction]
      send <draft-id>
      push --json '<event-json>'
    """)

    func runIntegrationsCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            print(Self.integrationsUsage)
            return
        }
        let args = Array(commandArgs.dropFirst())
        switch subcommand {
        case "list", "status":
            try ensureNoIntegrationArguments(args, command: subcommand)
            let payload = try client.sendV2(method: "integrations.status")
            printIntegrationStatus(payload, jsonOutput: jsonOutput)
        case "connect":
            let payload = try runIntegrationsConnect(args: args, client: client)
            printIntegrationMutation(payload, jsonOutput: jsonOutput)
        case "disconnect":
            let payload = try runIntegrationsDisconnect(args: args, client: client)
            printIntegrationMutation(payload, jsonOutput: jsonOutput)
        case "sync":
            let payload = try runIntegrationsSync(args: args, client: client)
            printIntegrationSync(payload, jsonOutput: jsonOutput)
        case "help":
            print(Self.integrationsUsage)
        default:
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.integrations.error.unknownSubcommand", defaultValue: "Unknown integrations subcommand: %@"),
                subcommand
            ))
        }
    }

    func runInboxCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            print(Self.inboxUsage)
            return
        }
        let args = Array(commandArgs.dropFirst())
        switch subcommand {
        case "list":
            try runInboxList(args: args, client: client, jsonOutput: jsonOutput)
        case "search":
            try runInboxSearch(args: args, client: client, jsonOutput: jsonOutput)
        case "mark-read":
            try runInboxMarkRead(args: args, client: client, jsonOutput: jsonOutput)
        case "draft":
            try runInboxDraft(args: args, client: client, jsonOutput: jsonOutput)
        case "send":
            try runInboxSend(args: args, client: client, jsonOutput: jsonOutput)
        case "push":
            try runInboxPush(args: args, client: client, jsonOutput: jsonOutput)
        case "help":
            print(Self.inboxUsage)
        default:
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.inbox.error.unknownSubcommand", defaultValue: "Unknown inbox subcommand: %@"),
                subcommand
            ))
        }
    }

    private func runIntegrationsConnect(args: [String], client: SocketClient) throws -> [String: Any] {
        guard let source = args.first?.lowercased(), isInboxSource(source) else {
            throw CLIError(message: String(localized: "cli.integrations.error.connectRequiresSource", defaultValue: "integrations connect requires gmail, slack, discord, imessage, or notifications"))
        }
        let rest = Array(args.dropFirst())
        let (accountID, afterAccount) = parseOption(rest, name: "--account")
        let (displayName, afterDisplayName) = parseOption(afterAccount, name: "--display-name")
        let (tokenEnv, afterTokenEnv) = parseOption(afterDisplayName, name: "--token-env")
        let (tokenStdin, remaining) = removeFlag(afterTokenEnv, names: ["--token-stdin"])
        try ensureNoIntegrationArguments(remaining, command: "connect")
        var params: [String: Any] = ["source": source]
        if let accountID { params["account_id"] = accountID }
        if let displayName { params["display_name"] = displayName }
        if let token = try integrationToken(tokenEnv: tokenEnv, tokenStdin: tokenStdin) {
            params["token"] = token
        }
        return try client.sendV2(method: "integrations.connect", params: params)
    }

    private func runIntegrationsDisconnect(args: [String], client: SocketClient) throws -> [String: Any] {
        guard let source = args.first?.lowercased(), isInboxSource(source) else {
            throw CLIError(message: String(localized: "cli.integrations.error.disconnectRequiresSource", defaultValue: "integrations disconnect requires a source"))
        }
        let rest = Array(args.dropFirst())
        let (accountFlag, remaining) = parseOption(rest, name: "--account")
        let positional = remaining.filter { !$0.hasPrefix("--") }
        if remaining.contains(where: { $0.hasPrefix("--") }) || positional.count > 1 {
            throw CLIError(message: String(localized: "cli.integrations.error.disconnectUsage", defaultValue: "Usage: cmux integrations disconnect <source> [account]"))
        }
        var params: [String: Any] = ["source": source]
        if let accountID = accountFlag ?? positional.first {
            params["account_id"] = accountID
        }
        return try client.sendV2(method: "integrations.disconnect", params: params)
    }

    private func runIntegrationsSync(args: [String], client: SocketClient) throws -> [String: Any] {
        guard args.count <= 1 else {
            throw CLIError(message: String(localized: "cli.integrations.error.syncUsage", defaultValue: "Usage: cmux integrations sync <source|all>"))
        }
        let source = args.first?.lowercased()
        var params: [String: Any] = [:]
        if let source, source != "all" {
            guard isInboxSource(source) else {
                throw CLIError(message: String(localized: "cli.integrations.error.invalidSource", defaultValue: "Invalid integration source"))
            }
            params["source"] = source
        }
        return try client.sendV2(method: "integrations.sync", params: params)
    }

    private func runInboxList(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (source, afterSource) = parseOption(args, name: "--source")
        let (limit, afterLimit) = parseOption(afterSource, name: "--limit")
        let (unread, afterUnread) = removeFlag(afterLimit, names: ["--unread"])
        let (actionable, remaining) = removeFlag(afterUnread, names: ["--actionable"])
        try ensureNoInboxArguments(remaining, command: "list")
        var params: [String: Any] = [:]
        if let source { params["source"] = try validatedInboxSource(source) }
        if unread { params["unread"] = true }
        if actionable { params["actionable"] = true }
        if let limit { params["limit"] = try positiveInt(limit, option: "--limit") }
        let payload = try client.sendV2(method: "inbox.list", params: params)
        printInboxItems(payload, jsonOutput: jsonOutput)
    }

    private func runInboxSearch(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (limit, remaining) = parseOption(args, name: "--limit")
        try ensureNoUnknownFlag(remaining, command: "search")
        let query = remaining.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw CLIError(message: String(localized: "cli.inbox.error.searchRequiresQuery", defaultValue: "inbox search requires a query"))
        }
        var params: [String: Any] = ["query": query]
        if let limit { params["limit"] = try positiveInt(limit, option: "--limit") }
        let payload = try client.sendV2(method: "inbox.search", params: params)
        printInboxSearch(payload, jsonOutput: jsonOutput)
    }

    private func runInboxMarkRead(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let (unread, afterUnread) = removeFlag(args, names: ["--unread"])
        let (threadFlag, afterThread) = removeFlag(afterUnread, names: ["--thread"])
        let (itemFlag, remaining) = removeFlag(afterThread, names: ["--item"])
        guard threadFlag == false || itemFlag == false else {
            throw CLIError(message: String(localized: "cli.inbox.error.markReadSelector", defaultValue: "mark-read accepts either --thread or --item"))
        }
        try ensureNoUnknownFlag(remaining, command: "mark-read")
        guard remaining.count == 1, let id = remaining.first else {
            throw CLIError(message: String(localized: "cli.inbox.error.markReadUsage", defaultValue: "Usage: cmux inbox mark-read <item-id|thread-id> [--thread|--item] [--unread]"))
        }
        var params: [String: Any] = ["unread": unread]
        if threadFlag || id.hasPrefix("thread:") {
            params["thread_id"] = id
        } else {
            params["item_id"] = id
        }
        let payload = try client.sendV2(method: "inbox.mark_read", params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: .uuids, fallbackText: String(localized: "common.ok", defaultValue: "OK"))
    }

    private func runInboxDraft(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard let threadID = args.first else {
            throw CLIError(message: String(localized: "cli.inbox.error.draftRequiresThread", defaultValue: "inbox draft requires a thread id"))
        }
        let instruction = Array(args.dropFirst()).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: Any] = ["thread_id": threadID]
        if !instruction.isEmpty { params["instruction"] = instruction }
        let payload = try client.sendV2(method: "inbox.draft_reply", params: params)
        printInboxDraft(payload, jsonOutput: jsonOutput)
    }

    private func runInboxSend(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        guard args.count == 1, let draftID = args.first else {
            throw CLIError(message: String(localized: "cli.inbox.error.sendRequiresDraft", defaultValue: "Usage: cmux inbox send <draft-id>"))
        }
        let payload = try client.sendV2(method: "inbox.send_reply", params: ["draft_id": draftID])
        printInboxDraft(payload, jsonOutput: jsonOutput)
    }

    private func runInboxPush(args: [String], client: SocketClient, jsonOutput: Bool) throws {
        let object = try inboxPushObject(args)
        let payload = try client.sendV2(method: "inbox.push", params: object)
        if jsonOutput {
            print(jsonString(payload))
        } else {
            let item = payload["item"] as? [String: Any]
            let id = item?["id"] as? String ?? String(localized: "cli.inbox.output.pushed", defaultValue: "pushed")
            print(String.localizedStringWithFormat(
                String(localized: "cli.inbox.output.pushSummary", defaultValue: "Pushed %@"),
                id
            ))
        }
    }

    private func integrationToken(tokenEnv: String?, tokenStdin: Bool) throws -> String? {
        if let tokenEnv {
            let value = ProcessInfo.processInfo.environment[tokenEnv]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.integrations.error.missingTokenEnv", defaultValue: "Environment variable %@ is empty or missing"),
                    tokenEnv
                ))
            }
            return value
        }
        guard tokenStdin else { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            throw CLIError(message: String(localized: "cli.integrations.error.emptyTokenStdin", defaultValue: "No token was read from standard input"))
        }
        return value
    }

    private func inboxPushObject(_ args: [String]) throws -> [String: Any] {
        var args = args
        if args.first == "--json" { args.removeFirst() }
        guard args.count == 1, let raw = args.first else {
            throw CLIError(message: String(localized: "cli.inbox.error.pushUsage", defaultValue: "Usage: cmux inbox push --json '<event-json>'"))
        }
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: String(localized: "cli.inbox.error.pushInvalidJSON", defaultValue: "inbox push requires a JSON object"))
        }
        return object
    }

    private func printIntegrationStatus(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        let statuses = payload["statuses"] as? [[String: Any]] ?? []
        guard !statuses.isEmpty else {
            print(String(localized: "cli.integrations.output.noIntegrations", defaultValue: "No integrations available"))
            return
        }
        for status in statuses {
            print(integrationStatusLine(status))
        }
    }

    private func printIntegrationMutation(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        print(integrationStatusLine(payload["status"] as? [String: Any] ?? payload))
    }

    private func printIntegrationSync(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        let statuses = payload["statuses"] as? [[String: Any]] ?? []
        if statuses.isEmpty {
            print(String(localized: "common.ok", defaultValue: "OK"))
        } else {
            statuses.forEach { print(integrationStatusLine($0)) }
        }
    }

    private func integrationStatusLine(_ status: [String: Any]) -> String {
        let source = status["source"] as? String ?? "?"
        let account = status["account_id"] as? String ?? "default"
        let state = status["status"] as? String ?? "unknown"
        let message = status["message"] as? String ?? status["status_message"] as? String
        return [source, account, state, message].compactMap { $0 }.joined(separator: "\t")
    }

    private func printInboxItems(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        let items = payload["items"] as? [[String: Any]] ?? []
        if items.isEmpty {
            print(String(localized: "cli.inbox.output.noItems", defaultValue: "No inbox items"))
            return
        }
        items.forEach { print(inboxItemLine($0)) }
    }

    private func printInboxSearch(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        let hits = payload["hits"] as? [[String: Any]] ?? []
        if hits.isEmpty {
            print(String(localized: "cli.inbox.output.noSearchResults", defaultValue: "No inbox search results"))
            return
        }
        for hit in hits {
            let item = hit["item"] as? [String: Any] ?? [:]
            print(inboxItemLine(item))
        }
    }

    private func printInboxDraft(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        let draft = payload["draft"] as? [String: Any] ?? payload
        let id = draft["draft_id"] as? String ?? draft["id"] as? String ?? "?"
        let status = draft["status"] as? String ?? "editing"
        let body = draft["body"] as? String ?? ""
        print("\(id)\t\(status)")
        if !body.isEmpty { print(body) }
    }

    private func inboxItemLine(_ item: [String: Any]) -> String {
        let source = item["source"] as? String ?? "?"
        let sender = (item["sender"] as? [String: Any])?["display_name"] as? String ?? "?"
        let unread = boolFromAny(item["unread"]) == true ? "unread" : "read"
        let actionable = boolFromAny(item["actionable"]) == true ? " actionable" : ""
        let preview = item["body_preview"] as? String ?? ""
        return "\(source)\t\(sender)\t\(unread)\(actionable)\t\(preview)"
    }

    private func ensureNoIntegrationArguments(_ args: [String], command: String) throws {
        guard args.isEmpty else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.integrations.error.unexpectedArgument", defaultValue: "integrations %@: unexpected argument '%@'"),
                command,
                args[0]
            ))
        }
    }

    private func ensureNoInboxArguments(_ args: [String], command: String) throws {
        guard args.isEmpty else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.inbox.error.unexpectedArgument", defaultValue: "inbox %@: unexpected argument '%@'"),
                command,
                args[0]
            ))
        }
    }

    private func ensureNoUnknownFlag(_ args: [String], command: String) throws {
        if let unknown = args.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.inbox.error.unknownFlag", defaultValue: "inbox %@: unknown flag '%@'"),
                command,
                unknown
            ))
        }
    }

    private func removeFlag(_ args: [String], names: Set<String>) -> (Bool, [String]) {
        var found = false
        let remaining = args.filter { arg in
            if names.contains(arg) {
                found = true
                return false
            }
            return true
        }
        return (found, remaining)
    }

    private func positiveInt(_ raw: String, option: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.inbox.error.positiveInt", defaultValue: "%@ must be a positive integer"),
                option
            ))
        }
        return value
    }

    private func validatedInboxSource(_ raw: String) throws -> String {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isInboxSource(source) else {
            throw CLIError(message: String(localized: "cli.inbox.error.invalidSource", defaultValue: "Invalid inbox source"))
        }
        return source
    }

    private func isInboxSource(_ source: String) -> Bool {
        ["agent", "gmail", "slack", "discord", "imessage", "notifications", "generic"].contains(source)
    }
}
