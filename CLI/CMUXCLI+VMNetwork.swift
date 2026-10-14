import Foundation

// MARK: - `cmux vm network`

extension CMUXCLI {
    static var vmNetworkUsage: String {
        String(
            localized: "cli.vm.network.usage",
            defaultValue: "Usage:\n  cmux vm network <id>                                   Show the machine's outbound policy.\n  cmux vm network <id> set --mode <full|allowlist|none> [--dns <on|off>]\n  cmux vm network <id> set --policy <json>               Replace the whole policy.\n  cmux vm network <id> add-domain <domain>...\n  cmux vm network <id> remove-domain <domain>...\n  cmux vm network <id> add-range <cidr> [--port <n>] [--protocol <tcp|udp>] [--note <text>]\n  cmux vm network <id> remove-range <cidr> [--port <n>] [--protocol <tcp|udp>]\n  cmux vm network <id> preset <add|remove> <preset-id>...\n\nModes: full reaches any public address; allowlist reaches only the listed\ndomains and ranges; none reaches nothing. cmux's own hosts stay reachable\nin every mode. Domains are exact HTTPS host names (no wildcards). A range\nwith --port and no --protocol means TCP. Open DNS (--dns on) is itself an\noutbound channel. Changes apply live to a running machine, with no restart.\n`cmux vm network <id>` lists the preset ids. Add --json for the structured result."
        )
    }

    /// Parses `vm new --network-policy <json>` / `--network <mode>` into the
    /// `network_policy` socket param. The app and the server validate the rest.
    static func parseVMCreateNetworkPolicy(json: String?, mode: String?) throws -> VMCreateNetworkPolicy? {
        if json != nil, mode != nil {
            throw CLIError(message: String(
                localized: "cli.vm.new.networkConflict",
                defaultValue: "vm new: use either --network or --network-policy, not both."
            ))
        }
        if let json {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["mode"] is String else {
                throw CLIError(message: String(
                    localized: "cli.vm.network.invalidPolicyJSON",
                    defaultValue: "The network policy must be a JSON object with a mode, for example {\"mode\":\"none\"}."
                ))
            }
            return VMCreateNetworkPolicy(object: object)
        }
        if let mode {
            let normalized = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.vmNetworkModes.contains(normalized) else {
                throw CLIError(message: String(
                    localized: "cli.vm.network.invalidMode",
                    defaultValue: "vm network: the mode must be full, allowlist, or none."
                ))
            }
            return VMCreateNetworkPolicy(object: ["version": 1, "mode": normalized])
        }
        return nil
    }

    private static let vmNetworkModes: Set<String> = ["full", "allowlist", "none"]

    /// One shared path for every `vm network` verb: reads go to `vm.network_get`,
    /// changes become edits for `vm.network_update`, which the app applies with
    /// the same rules as the Network sheet.
    func runVMNetworkCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmNetworkUsage)
            return
        }
        let json = jsonOutput || rest.contains("--json")
        let args = rest.filter { $0 != "--json" }
        guard let vmId = args.first, !vmId.hasPrefix("-") else {
            throw CLIError(message: Self.vmNetworkUsage)
        }
        let verbArgs = Array(args.dropFirst())
        let response: [String: Any]
        if let verb = verbArgs.first?.lowercased() {
            let edits = try vmNetworkEdits(verb: verb, args: Array(verbArgs.dropFirst()))
            response = try client.sendV2(
                method: "vm.network_update",
                params: ["id": vmId, "edits": edits],
                responseTimeout: 90
            )
        } else {
            response = try client.sendV2(method: "vm.network_get", params: ["id": vmId], responseTimeout: 60)
        }
        if json {
            print(jsonString(response))
            return
        }
        print(Self.formatVMNetwork(id: vmId, payload: response))
    }

    /// Maps one verb and its arguments to socket edit objects.
    func vmNetworkEdits(verb: String, args: [String]) throws -> [[String: Any]] {
        let usage = CLIError(message: Self.vmNetworkUsage)
        switch verb {
        case "set":
            let (modeOpt, r1) = parseOption(args, name: "--mode")
            let (dnsOpt, r2) = parseOption(r1, name: "--dns")
            let (policyOpt, remaining) = parseOption(r2, name: "--policy")
            guard remaining.isEmpty, modeOpt != nil || dnsOpt != nil || policyOpt != nil else { throw usage }
            var edits: [[String: Any]] = []
            if let policyOpt {
                guard modeOpt == nil, dnsOpt == nil,
                      let policy = try Self.parseVMCreateNetworkPolicy(json: policyOpt, mode: nil) else { throw usage }
                edits.append(["op": "replace", "policy": policy.object])
            }
            if let modeOpt {
                let mode = modeOpt.lowercased()
                guard Self.vmNetworkModes.contains(mode) else {
                    throw CLIError(message: String(
                        localized: "cli.vm.network.invalidMode",
                        defaultValue: "vm network: the mode must be full, allowlist, or none."
                    ))
                }
                edits.append(["op": "set_mode", "mode": mode])
            }
            if let dnsOpt {
                switch dnsOpt.lowercased() {
                case "on", "true", "yes", "1": edits.append(["op": "set_dns", "allow_dns": true])
                case "off", "false", "no", "0": edits.append(["op": "set_dns", "allow_dns": false])
                default:
                    throw CLIError(message: String(
                        localized: "cli.vm.network.invalidDns",
                        defaultValue: "vm network: --dns takes on or off."
                    ))
                }
            }
            return edits
        case "add-domain", "remove-domain":
            guard !args.isEmpty, !args.contains(where: { $0.hasPrefix("-") }) else { throw usage }
            let op = verb == "add-domain" ? "add_domain" : "remove_domain"
            return args.map { ["op": op, "domain": $0] }
        case "add-range", "remove-range":
            let (portOpt, r1) = parseOption(args, name: "--port")
            let (protocolOpt, r2) = parseOption(r1, name: "--protocol")
            let (noteOpt, remaining) = parseOption(r2, name: "--note")
            guard remaining.count == 1, let cidr = remaining.first, !cidr.hasPrefix("-") else { throw usage }
            if verb == "remove-range", noteOpt != nil { throw usage }
            var edit: [String: Any] = ["op": verb == "add-range" ? "add_range" : "remove_range", "cidr": cidr]
            if let portOpt {
                guard let port = Int(portOpt), (1...65_535).contains(port) else {
                    throw CLIError(message: String(
                        localized: "cli.vm.network.invalidPort",
                        defaultValue: "vm network: --port must be a number from 1 to 65535."
                    ))
                }
                edit["port"] = port
            }
            if let protocolOpt {
                let transport = protocolOpt.lowercased()
                guard transport == "tcp" || transport == "udp" else {
                    throw CLIError(message: String(
                        localized: "cli.vm.network.invalidProtocol",
                        defaultValue: "vm network: --protocol takes tcp or udp."
                    ))
                }
                edit["protocol"] = transport
            }
            if let noteOpt { edit["note"] = noteOpt }
            return [edit]
        case "preset", "presets":
            guard let action = args.first?.lowercased(), action == "add" || action == "remove" else { throw usage }
            let ids = Array(args.dropFirst())
            guard !ids.isEmpty, !ids.contains(where: { $0.hasPrefix("-") }) else { throw usage }
            let op = action == "add" ? "add_preset" : "remove_preset"
            return ids.map { ["op": op, "preset": $0] }
        default:
            throw usage
        }
    }

    /// Human-readable policy, one fact per line.
    static func formatVMNetwork(id: String, payload: [String: Any]) -> String {
        let policy = payload["policy"] as? [String: Any] ?? [:]
        let mode = policy["mode"] as? String ?? "full"
        var lines: [String] = []
        var header = "\(id)  mode=\(mode)"
        if mode == "allowlist" {
            header += "  dns=\((policy["allowDns"] as? Bool ?? true) ? "on" : "off")"
        }
        if let applied = payload["applied"] as? [String: Any], let state = applied["state"] as? String {
            header += "  applied=\(state)"
            if let at = applied["appliedAt"] as? String, !at.isEmpty { header += " (\(at))" }
        }
        lines.append(header)
        if let applied = payload["applied"] as? [String: Any], let error = applied["error"] as? String, !error.isEmpty {
            lines.append("error: \(error)")
        }
        let presets = policy["presets"] as? [String] ?? []
        let domains = policy["domains"] as? [String] ?? []
        let ranges = policy["ranges"] as? [[String: Any]] ?? []
        if mode != "allowlist", !presets.isEmpty || !domains.isEmpty || !ranges.isEmpty {
            lines.append(String(
                localized: "cli.vm.network.listsInactive",
                defaultValue: "(the lists below take effect only in allowlist mode)"
            ))
        }
        lines.append("presets: \(presets.isEmpty ? "-" : presets.joined(separator: ", "))")
        lines.append(domains.isEmpty ? "domains: -" : "domains:")
        lines.append(contentsOf: domains.map { "  \($0)" })
        lines.append(ranges.isEmpty ? "ranges: -" : "ranges:")
        for range in ranges {
            var line = "  \(range["cidr"] as? String ?? "?")"
            if let port = range["port"] as? Int { line += " \(range["protocol"] as? String ?? "tcp")/\(port)" }
            if let note = range["note"] as? String, !note.isEmpty { line += "  # \(note)" }
            lines.append(line)
        }
        if let required = payload["requiredDomains"] as? [String], !required.isEmpty {
            lines.append("always allowed: \(required.joined(separator: ", "))")
        }
        if let catalog = payload["presets"] as? [[String: Any]], !catalog.isEmpty {
            let ids = catalog.compactMap { $0["id"] as? String }
            lines.append("available presets: \(ids.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

/// A `vm new` network policy: the JSON object sent as `network_policy`, plus
/// a stable text form for the create idempotency scope.
struct VMCreateNetworkPolicy {
    let object: [String: Any]

    var canonicalJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
