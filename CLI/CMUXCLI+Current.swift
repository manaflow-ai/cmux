import Foundation

/// One invocation's options and presentation; native owners capture all work facts.
struct CurrentCommand {
    static let usage = String(localized: "cli.current.help", defaultValue: """
            Usage: cmux current [--limit <1...200>] [--json]

            Read bounded current-work facts already known to cmux across local and Cloud surfaces.
            Does not refresh machines, read transcripts, or mutate work.

            Flags:
              --limit <1...200>  Maximum items (default: 100)
              --json            Exact owner payload with identities, evidence and freshness

            Text and JSON use the same snapshot. Unknown facts remain unknown; possible
            human obligations are observations, not permission to act. --window does not
            focus or filter this app-wide query; --id-format does not rewrite its identities.

            Examples:
              cmux current
              cmux current --json --limit 50
            """)

    struct Options {
        var limit: Int?
        var jsonOutput = false
    }

    let options: Options

    init(arguments args: [String]) throws {
        var result = Options()
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--json" {
                result.jsonOutput = true
            } else if argument == "--limit" || argument.hasPrefix("--limit=") {
                guard result.limit == nil else {
                    throw CLIError(message: String(localized: "cli.current.error.duplicateLimit", defaultValue: "current: --limit may only be supplied once"))
                }
                let raw: String
                if argument == "--limit" {
                    index += 1
                    guard index < args.count else {
                        throw CLIError(message: String(localized: "cli.current.error.limit", defaultValue: "current: --limit requires an integer from 1 to 200"))
                    }
                    raw = args[index]
                } else {
                    raw = String(argument.dropFirst("--limit=".count))
                }
                guard let limit = Int(raw), (1...200).contains(limit) else {
                    throw CLIError(message: String(localized: "cli.current.error.limit", defaultValue: "current: --limit requires an integer from 1 to 200"))
                }
                result.limit = limit
            } else {
                throw CLIError(message: String.localizedStringWithFormat(String(localized: "cli.current.error.argument", defaultValue: "current: unexpected argument '%@'. Known flags: --limit <1...200> --json"), argument))
            }
            index += 1
        }
        options = result
    }

    func render(_ payload: [String: Any]) throws -> String {
        guard let items = payload["items"] as? [[String: Any]] else {
            throw CLIError(message: String(localized: "cli.current.error.response", defaultValue: "current: invalid response (missing items)"))
        }
        var lines: [String] = []
        if items.isEmpty {
            lines.append(String(localized: "cli.current.empty", defaultValue: "No current work observed"))
        }
        for item in items {
            let label = display(item["label"] as? String ?? item["resource_ref"] as? String ?? "?")
            let resource = display(item["resource_ref"] as? String ?? "unknown")
            let placement = item["placement"] as? [String: Any] ?? [:]
            let kind = display(placement["kind"] as? String ?? "unknown")
            let machine = display(placement["machine"] as? String ?? "unknown")
            lines.append("\(label)  [\(kind): \(machine)]")
            lines.append("  \(resource)")
            if let cwd = item["cwd"] as? String, !cwd.isEmpty {
                lines.append("  " + String.localizedStringWithFormat(String(localized: "cli.current.cwd", defaultValue: "cwd: %@"), display(cwd)))
            }
            let freshness = item["freshness"] as? [String: Any] ?? [:]
            lines.append("  " + String.localizedStringWithFormat(String(localized: "cli.current.freshness", defaultValue: "freshness: %@"), display(freshness["state"] as? String ?? "unknown")))
            let attention = item["attention"] as? [[String: Any]] ?? []
            if !attention.isEmpty {
                let kinds = attention.compactMap { $0["kind"] as? String }.map(display)
                lines.append("  " + String.localizedStringWithFormat(String(localized: "cli.current.attention", defaultValue: "attention: %@"), kinds.joined(separator: ", ")))
            }
            let agents = item["agents"] as? [[String: Any]] ?? []
            let pullRequests = item["pull_requests"] as? [[String: Any]] ?? []
            let obligations = item["possible_human_obligations"] as? [[String: Any]] ?? []
            for agent in agents {
                let fact = [agent["kind"] as? String, agent["state"] as? String].compactMap { $0 }.map(display).joined(separator: " · ")
                lines.append("  " + String.localizedStringWithFormat(String(localized: "cli.current.agent", defaultValue: "agent: %@"), fact))
            }
            for pullRequest in pullRequests {
                let label = pullRequest["label"] as? String ?? (pullRequest["number"] as? NSNumber).map { "#" + $0.stringValue } ?? "?"
                let fact = [label, pullRequest["status"] as? String].compactMap { $0 }.map(display).joined(separator: " · ")
                lines.append("  " + String.localizedStringWithFormat(String(localized: "cli.current.pullRequest", defaultValue: "PR: %@"), fact))
            }
            for obligation in obligations {
                let fact = display(obligation["kind"] as? String ?? "unknown")
                lines.append("  " + String.localizedStringWithFormat(String(localized: "cli.current.obligation", defaultValue: "possible human obligation: %@"), fact))
            }
        }
        if payload["truncated"] as? Bool == true {
            lines.append(String(localized: "cli.current.limited", defaultValue: "Limit reached; more work was observed. Use --limit (maximum 200)."))
        }
        if let observedAt = payload["observed_at"] as? String {
            lines.append(String.localizedStringWithFormat(String(localized: "cli.current.observed", defaultValue: "Observed: %@; cached owner facts, no refresh"), display(observedAt)))
        }
        if let availability = payload["owner_availability"] as? [String: String] {
            for owner in availability.keys.sorted() where availability[owner] != "available" {
                lines.append(String.localizedStringWithFormat(String(localized: "cli.current.owner", defaultValue: "Owner %@: %@"), display(owner), display(availability[owner] ?? "unknown")))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Owner labels and paths can contain terminal control characters. JSON retains
    /// exact data, while human output must not execute escape sequences or add rows.
    private func display(_ text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
    }
}

extension CMUXCLI {
    func runCurrentCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let command = try CurrentCommand(arguments: commandArgs)
        var params: [String: Any] = [:]
        if let limit = command.options.limit { params["limit"] = limit }
        let payload = try client.sendV2(method: "current.list", params: params)
        if jsonOutput || command.options.jsonOutput {
            // Preserve stable resource/projection ids and unknown owner fields.
            // --id-format must not rewrite this resource-oriented read contract.
            print(jsonString(payload))
        } else {
            print(try command.render(payload))
        }
    }
}
