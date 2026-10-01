import Foundation

extension CMUXCLI {
    func runAutomationCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())
        try Self.validateAutomationArguments(subcommand: subcommand, arguments: rest)
        let response: [String: Any]

        switch subcommand {
        case "list":
            response = try client.sendV2(method: "automation.list")
        case "show":
            guard let id = rest.first, !id.isEmpty, !id.hasPrefix("--") else {
                throw CLIError(message: Self.automationUsage())
            }
            response = try client.sendV2(method: "automation.show", params: ["id": id])
        case "test":
            guard let id = rest.first, !id.isEmpty, !id.hasPrefix("--") else {
                throw CLIError(message: Self.automationUsage())
            }
            let event = try parseAutomationEvent(Array(rest.dropFirst()))
            response = try client.sendV2(method: "automation.test", params: ["id": id, "event": event])
        case "enable", "disable":
            guard let id = rest.first, !id.isEmpty, !id.hasPrefix("--") else {
                throw CLIError(message: Self.automationUsage())
            }
            response = try client.sendV2(
                method: subcommand == "enable" ? "automation.enable" : "automation.disable",
                params: ["id": id]
            )
        case "logs":
            var params: [String: Any] = [:]
            if let limit = try Self.automationLimit(from: rest) {
                params["limit"] = limit
            }
            response = try client.sendV2(method: "automation.logs", params: params)
        case "reload":
            response = try client.sendV2(method: "automation.reload")
        case "help", "--help", "-h":
            print(Self.automationUsage())
            return
        default:
            throw CLIError(message: Self.automationUsage())
        }

        if jsonOutput {
            print(jsonString(response))
            return
        }
        printAutomationResponse(response, subcommand: subcommand)
    }

    /// The test command can run without a live app, which makes it useful for
    /// validating a checked-in rule in CI. The app-backed path uses the same
    /// matcher through `automation.test` when a socket is available.
    func runAutomationOfflineTest(commandArgs: [String], jsonOutput: Bool) throws {
        guard let id = commandArgs.first, !id.isEmpty, !id.hasPrefix("--") else {
            throw CLIError(message: Self.automationUsage())
        }
        let event = try parseAutomationEvent(Array(commandArgs.dropFirst()))
        let store = AutomationConfigStore()
        let configuration: AutomationConfiguration
        do {
            configuration = try store.load()
        } catch {
            throw CLIError(message: String(describing: error))
        }
        guard let rule = configuration.rules.first(where: { $0.id == id }) else {
            let format = automationLocalized(
                "automation.error.ruleNotFound",
                defaultValue: "Automation rule not found: %@"
            )
            throw CLIError(message: String.localizedStringWithFormat(format, id))
        }
        guard !rule.usesWorkspaceTagPredicate || automationEventProvidesWorkspaceTags(event) else {
            throw CLIError(message: automationLocalized(
                "cli.automation.error.workspaceTagsRequired",
                defaultValue: "offline automation test requires workspace tags in the event payload"
            ))
        }
        let matched = rule.matches(event: event)
        let redactor = AutomationPayloadRedactor()
        let payload: [String: Any] = [
            "id": id,
            "enabled": rule.enabled,
            "matched": matched,
            "event": redactor.event(event),
            "actions": rule.actions.map(redactor.actionPayload),
            "dry_run": true,
            "reason": matched ? "matched" : "predicate_mismatch"
        ]
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print(jsonString(payload))
        }
    }

    /// Validates the argument shape before any automation RPC is sent.
    ///
    /// Keeping this separate from the socket-backed command makes malformed
    /// requests fail locally and gives tests a pure parser contract to cover.
    static func validateAutomationArguments(subcommand: String, arguments: [String]) throws {
        switch subcommand {
        case "list", "reload":
            guard arguments.isEmpty else { throw CLIError(message: Self.automationUsage()) }
        case "show", "enable", "disable":
            guard arguments.count == 1,
                  let id = arguments.first,
                  !id.isEmpty,
                  !id.hasPrefix("--") else {
                throw CLIError(message: Self.automationUsage())
            }
        case "test":
            guard let id = arguments.first,
                  !id.isEmpty,
                  !id.hasPrefix("--") else {
                throw CLIError(message: Self.automationUsage())
            }
            try validateAutomationEventArguments(Array(arguments.dropFirst()))
        case "logs":
            _ = try Self.automationLimit(from: arguments)
        case "help", "--help", "-h":
            break
        default:
            throw CLIError(message: Self.automationUsage())
        }
    }

    private static func validateAutomationEventArguments(_ args: [String]) throws {
        let markers = args.indices.filter { index in
            args[index] == "--event" || args[index].hasPrefix("--event=")
        }
        guard markers.count == 1, let markerIndex = markers.first else {
            throw CLIError(message: String(
                localized: "cli.automation.error.eventFlag",
                defaultValue: "automation test requires --event <json>"
            ))
        }
        guard markerIndex == 0 else {
            throw CLIError(message: Self.automationUsage())
        }
        let marker = args[markerIndex]
        if marker == "--event" {
            guard markerIndex + 1 == args.count - 1 else {
                throw CLIError(message: Self.automationUsage())
            }
        } else if markerIndex != args.count - 1 {
            throw CLIError(message: Self.automationUsage())
        }
    }

    private func parseAutomationEvent(_ args: [String]) throws -> [String: Any] {
        try Self.validateAutomationEventArguments(args)
        let markerIndex = args.firstIndex(where: { $0 == "--event" || $0.hasPrefix("--event=") })!
        let marker = args[markerIndex]
        let raw: String
        if let inline = marker.split(separator: "=", maxSplits: 1).dropFirst().first {
            raw = String(inline)
        } else {
            let valueStart = markerIndex + 1
            guard valueStart < args.count else {
                throw CLIError(message: automationLocalized(
                    "cli.automation.error.eventFlag",
                    defaultValue: "automation test requires --event <json>"
                ))
            }
            raw = args[valueStart]
        }
        let data: Data
        if raw.hasPrefix("@") {
            data = try boundedAutomationEventData(
                at: URL(fileURLWithPath: String(raw.dropFirst())).standardizedFileURL
            )
        } else {
            guard let encoded = raw.data(using: .utf8),
                  encoded.count <= AutomationConfigStore.maximumJSONInputBytes else {
                throw CLIError(message: automationLocalized(
                    "cli.automation.error.eventObject",
                    defaultValue: "automation test event must be a JSON object"
                ))
            }
            data = encoded
        }
        do {
            try AutomationConfigStore.validateJSONDepth(in: data)
        } catch {
            throw CLIError(message: automationLocalized(
                "cli.automation.error.eventObject",
                defaultValue: "automation test event must be a JSON object"
            ))
        }
        guard
              let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any] else {
            throw CLIError(message: automationLocalized(
                "cli.automation.error.eventObject",
                defaultValue: "automation test event must be a JSON object"
            ))
        }
        return event
    }

    private func boundedAutomationEventData(at url: URL) throws -> Data {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CLIError(message: automationLocalized(
                "cli.automation.error.eventObject",
                defaultValue: "automation test event must be a JSON object"
            ))
        }
        if let size = attributes[.size] as? NSNumber,
           size.uint64Value > UInt64(AutomationConfigStore.maximumJSONInputBytes) {
            throw CLIError(message: automationLocalized(
                "cli.automation.error.eventObject",
                defaultValue: "automation test event must be a JSON object"
            ))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try AutomationConfigStore.readBoundedData(
            maximumBytes: AutomationConfigStore.maximumJSONInputBytes
        ) { count in
            try handle.read(upToCount: count)
        }
        guard data.count <= AutomationConfigStore.maximumJSONInputBytes else {
            throw CLIError(message: automationLocalized(
                "cli.automation.error.eventObject",
                defaultValue: "automation test event must be a JSON object"
            ))
        }
        return data
    }

    private func printAutomationResponse(_ response: [String: Any], subcommand: String) {
        switch subcommand {
        case "list":
            let rules = response["rules"] as? [[String: Any]] ?? []
            if rules.isEmpty {
                print(automationLocalized("cli.automation.output.noRules", defaultValue: "No automation rules"))
                return
            }
            for rule in rules {
                let id = rule["id"] as? String ?? "?"
                let enabled = (rule["enabled"] as? Bool) == true
                    ? String(localized: "cli.automation.state.enabled", defaultValue: "enabled")
                    : String(localized: "cli.automation.state.disabled", defaultValue: "disabled")
                let event = rule["event"] as? String ?? rule["category"] as? String ?? "*"
                let format = String(
                    localized: "cli.automation.output.rule",
                    defaultValue: "%1$@ [%2$@] when %3$@"
                )
                print(String.localizedStringWithFormat(format, id, enabled, event))
            }
        case "reload":
            print(String(
                localized: "cli.automation.output.reloadRequested",
                defaultValue: "Automation configuration reload requested"
            ))
        case "enable", "disable":
            let id = response["id"] as? String ?? "?"
            if (response["pending"] as? Bool) == true {
                let format: String
                if subcommand == "enable" {
                    format = String(
                        localized: "cli.automation.output.enableRequested",
                        defaultValue: "Enable request queued for %@. Run cmux automation logs to verify completion."
                    )
                } else {
                    format = String(
                        localized: "cli.automation.output.disableRequested",
                        defaultValue: "Disable request queued for %@. Run cmux automation logs to verify completion."
                    )
                }
                print(String.localizedStringWithFormat(format, id))
                return
            }
            let format = (response["enabled"] as? Bool) == true
                ? String(localized: "cli.automation.output.enabled", defaultValue: "Enabled %@")
                : String(localized: "cli.automation.output.disabled", defaultValue: "Disabled %@")
            print(String.localizedStringWithFormat(format, id))
        default:
            print(jsonString(response))
        }
    }

    static func automationUsage() -> String {
        String(
            localized: "cli.automation.help",
            defaultValue: """
        Usage: cmux automation <list|show|test|enable|disable|logs|reload> [args]

        Rules live in ~/.cmuxterm/automations.json.
        Examples:
          cmux automation list
          cmux automation show surface-needs-input
          cmux automation test surface-needs-input --event '{"name":"agent.needs_input"}'
          cmux automation enable surface-needs-input
          cmux automation disable surface-needs-input
          cmux automation logs [--limit <n>]
          cmux automation reload
        """
        )
    }

    private func automationLocalized(_ key: String, defaultValue: String) -> String {
        switch key {
        case "automation.error.ruleNotFound":
            return String(localized: "automation.error.ruleNotFound", defaultValue: "Automation rule not found: %@")
        case "cli.automation.error.eventFlag":
            return String(localized: "cli.automation.error.eventFlag", defaultValue: "automation test requires --event <json>")
        case "cli.automation.error.eventObject":
            return String(localized: "cli.automation.error.eventObject", defaultValue: "automation test event must be a JSON object")
        case "cli.automation.output.noRules":
            return String(localized: "cli.automation.output.noRules", defaultValue: "No automation rules")
        case "cli.automation.error.workspaceTagsRequired":
            return String(localized: "cli.automation.error.workspaceTagsRequired", defaultValue: "offline automation test requires workspace tags in the event payload")
        default:
            return defaultValue
        }
    }

    private static func automationLimit(from args: [String]) throws -> Int? {
        guard args.isEmpty || args.count <= 2 else {
            throw CLIError(message: Self.automationUsage())
        }
        guard let index = args.firstIndex(where: { $0 == "--limit" || $0.hasPrefix("--limit=") }) else {
            guard args.isEmpty else { throw CLIError(message: Self.automationUsage()) }
            return nil
        }
        let argument = args[index]
        let rawLimit: String
        if argument == "--limit" {
            let valueIndex = index + 1
            guard valueIndex == args.count - 1, !args[valueIndex].hasPrefix("--") else {
                throw CLIError(message: Self.automationUsage())
            }
            rawLimit = args[valueIndex]
        } else {
            rawLimit = String(argument.dropFirst("--limit=".count))
            guard !rawLimit.isEmpty else {
                throw CLIError(message: Self.automationUsage())
            }
            guard args.count == 1 else { throw CLIError(message: Self.automationUsage()) }
        }
        guard let limit = Int(rawLimit) else {
            throw CLIError(message: Self.automationUsage())
        }
        return limit
    }

    private func automationEventProvidesWorkspaceTags(_ event: [String: Any]) -> Bool {
        let payload = event["payload"] as? [String: Any] ?? [:]
        return payload["workspace_tag"] != nil
            || payload["tag"] != nil
            || payload["tags"] != nil
    }
}
