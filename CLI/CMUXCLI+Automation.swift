import Foundation

extension CMUXCLI {
    func runAutomationCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "list"
        let rest = Array(commandArgs.dropFirst())
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
            if let rawLimit = optionValue(rest, name: "--limit"), let limit = Int(rawLimit) {
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
            throw CLIError(message: error.localizedDescription)
        }
        guard let rule = configuration.rules.first(where: { $0.id == id }) else {
            throw CLIError(message: automationLocalized(
                "automation.error.ruleNotFound",
                defaultValue: "Automation rule not found: \(id)"
            ).replacingOccurrences(of: "%@", with: id))
        }
        let matched = rule.matches(event: event)
        let payload: [String: Any] = [
            "id": id,
            "enabled": rule.enabled,
            "matched": matched,
            "event": event,
            "actions": rule.actions.map { action in
                var result: [String: Any] = ["action": action.action]
                for (key, value) in action.parameters { result[key] = value.foundationObject }
                return result
            },
            "dry_run": true,
            "reason": matched ? "matched" : "predicate_mismatch"
        ]
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print(jsonString(payload))
        }
    }

    private func parseAutomationEvent(_ args: [String]) throws -> [String: Any] {
        guard let markerIndex = args.firstIndex(where: { $0 == "--event" || $0.hasPrefix("--event=") }) else {
            throw CLIError(message: automationLocalized(
                "cli.automation.error.eventFlag",
                defaultValue: "automation test requires --event <json>"
            ))
        }
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
            raw = args[valueStart...].joined(separator: " ")
        }
        let expanded: String
        if raw.hasPrefix("@") {
            let url = URL(fileURLWithPath: String(raw.dropFirst())).standardizedFileURL
            expanded = try String(contentsOf: url, encoding: .utf8)
        } else {
            expanded = raw
        }
        guard let data = expanded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let event = object as? [String: Any] else {
            throw CLIError(message: automationLocalized(
                "cli.automation.error.eventObject",
                defaultValue: "automation test event must be a JSON object"
            ))
        }
        return event
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
                    defaultValue: "%@ [%@] when %@"
                )
                print(replacingFirstPlaceholder(
                    replacingFirstPlaceholder(
                        replacingFirstPlaceholder(format, with: id),
                        with: enabled
                    ),
                    with: event
                ))
            }
        case "reload":
            let count = response["rule_count"] as? Int ?? 0
            let format = String(
                localized: "cli.automation.output.reloaded",
                defaultValue: "Reloaded %@ automation rule(s)"
            )
            print(replacingFirstPlaceholder(format, with: String(count)))
        case "enable", "disable":
            let id = response["id"] as? String ?? "?"
            let format = (response["enabled"] as? Bool) == true
                ? String(localized: "cli.automation.output.enabled", defaultValue: "Enabled %@")
                : String(localized: "cli.automation.output.disabled", defaultValue: "Disabled %@")
            print(replacingFirstPlaceholder(format, with: id))
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
            return String(localized: "automation.error.ruleNotFound", defaultValue: "Automation rule not found")
        case "cli.automation.error.eventFlag":
            return String(localized: "cli.automation.error.eventFlag", defaultValue: "automation test requires --event <json>")
        case "cli.automation.error.eventObject":
            return String(localized: "cli.automation.error.eventObject", defaultValue: "automation test event must be a JSON object")
        case "cli.automation.output.noRules":
            return String(localized: "cli.automation.output.noRules", defaultValue: "No automation rules")
        default:
            return defaultValue
        }
    }

    private func replacingFirstPlaceholder(_ value: String, with replacement: String) -> String {
        guard let range = value.range(of: "%@") else { return value }
        return value.replacingCharacters(in: range, with: replacement)
    }
}
