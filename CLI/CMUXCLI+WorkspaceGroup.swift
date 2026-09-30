import Foundation

extension CMUXCLI {
    /// Emit a workspace-group mutation response, including removal impact.
    private func printWorkspaceGroupResponse(
        _ response: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
        } else if response["operation"] as? String == "dissolved",
                  let count = (response["kept_workspace_count"] as? NSNumber)?.intValue {
            let format = count == 1
                ? String(localized: "cli.workspaceGroup.response.dissolved.one", defaultValue: "OK group dissolved (kept %lld workspace)")
                : String(localized: "cli.workspaceGroup.response.dissolved.other", defaultValue: "OK group dissolved (kept %lld workspaces)")
            print(String.localizedStringWithFormat(format, Int64(count)))
        } else if response["operation"] as? String == "closed_workspaces",
                  let count = (response["closed_workspace_count"] as? NSNumber)?.intValue {
            let format = count == 1
                ? String(localized: "cli.workspaceGroup.response.closed.one", defaultValue: "OK group deleted (closed %lld workspace)")
                : String(localized: "cli.workspaceGroup.response.closed.other", defaultValue: "OK group deleted (closed %lld workspaces)")
            print(String.localizedStringWithFormat(format, Int64(count)))
        } else {
            print("OK")
        }
    }

    /// Print a one-time deprecation hint to stderr for a legacy CLI verb that
    /// has a `cmux workspace <subcommand>` replacement. Honors CMUX_QUIET so
    /// scripts can opt out.
    private static let cliDeprecationNoticeShownKey = "CMUX_CLI_DEPRECATION_SHOWN"
    static func warnLegacyVerbDeprecated(_ legacy: String, replacement: String) {
        if ProcessInfo.processInfo.environment["CMUX_QUIET"] != nil { return }
        if getenv(cliDeprecationNoticeShownKey) != nil { return }
        cliWriteStderr("cmux: '\(legacy)' is now an alias for '\(replacement)'. The legacy form keeps working indefinitely; set CMUX_QUIET=1 to silence this notice.\n")
        setenv(cliDeprecationNoticeShownKey, "1", 1)
    }

    func runWorkspaceGroup(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: "workspace-group requires a subcommand. Try: list, create, ungroup, delete, rename, collapse, expand, pin, unpin, add, join, remove, set-anchor, new-workspace, set-color, set-icon, move, focus")
        }
        let rest = Array(commandArgs.dropFirst())
        var params: [String: Any] = [:]
        try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowFromArgsOrOverride(rest, windowOverride: windowOverride))

        func resolveGroupId(in rest: [String]) throws -> String {
            let (gidOpt, rem0) = parseOption(rest, name: "--group")
            if let gidOpt { return gidOpt }
            // Strip --window before scanning for a positional so a `--window
            // <value>` pair never gets parsed as the group id.
            let (_, rem1) = parseOption(rem0, name: "--window")
            for arg in rem1 where !arg.hasPrefix("--") {
                return arg
            }
            throw CLIError(message: "workspace-group \(sub) requires a group id or --group <id>")
        }

        switch sub {
        case "list":
            let payload = try client.sendV2(method: "workspace.group.list", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(payload, mode: idFormat)))
            } else {
                let groups = payload["groups"] as? [[String: Any]] ?? []
                if groups.isEmpty {
                    print("No groups")
                } else {
                    for g in groups {
                        let handle = textHandle(g, idFormat: idFormat)
                        let name = (g["name"] as? String) ?? ""
                        let count = (g["member_count"] as? Int) ?? 0
                        let pin = (g["is_pinned"] as? Bool) == true ? " [pinned]" : ""
                        let coll = (g["is_collapsed"] as? Bool) == true ? " [collapsed]" : ""
                        print("\(handle)  \(name)  (\(count) members)\(pin)\(coll)")
                    }
                }
            }

        case "create":
            let (nameOpt, rem0) = parseOption(rest, name: "--name")
            let (cwdOpt, rem1) = parseOption(rem0, name: "--cwd")
            let (fromOpt, rem2) = parseOption(rem1, name: "--from")
            let (idempotencyOpt, rem3) = parseOption(rem2, name: "--idempotency-key")
            let (externalIDOpt, rem4) = parseOption(rem3, name: "--external-id")
            let (_, rem5) = parseOption(rem4, name: "--window")
            // Use the remainder AFTER every named option is stripped so the
            // positional name lookup can't pick up --from/--window values.
            let resolvedName = nameOpt ?? rem5.first(where: { !$0.hasPrefix("--") }) ?? ""
            params["name"] = resolvedName
            if let cwdOpt { params["cwd"] = resolvePath(cwdOpt) }
            if let idempotencyOpt { params["idempotency_key"] = idempotencyOpt }
            if let externalIDOpt { params["external_id"] = externalIDOpt }
            let ids = fromOpt?.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            } ?? []
            params["child_workspace_ids"] = ids
            let response = try client.sendV2(method: "workspace.group.create", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
            } else if let group = response["group"] as? [String: Any] {
                print("OK \(textHandle(group, idFormat: idFormat))")
            } else {
                print("OK")
            }

        case "ungroup":
            let optionTerminator = rest.firstIndex(of: "--") ?? rest.endIndex
            let removeAnchor = rest[..<optionTerminator].contains("--remove-generated-anchor")
            let routedArgs = rest.enumerated().compactMap { index, argument in
                index < optionTerminator && argument == "--remove-generated-anchor" ? nil : argument
            }
            params["group_id"] = try resolveGroupId(in: routedArgs)
            if removeAnchor { params["remove_generated_anchor"] = true }
            let resp = try client.sendV2(method: "workspace.group.ungroup", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "delete":
            let optionTerminator = rest.firstIndex(of: "--") ?? rest.endIndex
            let closesWorkspaces = rest[..<optionTerminator].contains("--close-workspaces")
            let routedArgs = rest.enumerated().compactMap { index, argument in
                index < optionTerminator && (argument == "--close-workspaces" || argument == "--remove-generated-anchor") ? nil : argument
            }
            params["group_id"] = try resolveGroupId(in: routedArgs)
            let method = closesWorkspaces ? "workspace.group.delete" : "workspace.group.ungroup"
            if closesWorkspaces { params["close_workspaces"] = true }
            if rest[..<optionTerminator].contains("--remove-generated-anchor") {
                params["remove_generated_anchor"] = true
            }
            let resp = try client.sendV2(method: method, params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "rename":
            let (nameOpt, rem0) = parseOption(rest, name: "--name")
            let gid = try resolveGroupId(in: rem0)
            params["group_id"] = gid
            let positional = rem0.filter { !$0.hasPrefix("--") && $0 != gid }
            guard let newName = nameOpt ?? positional.first else {
                throw CLIError(message: "rename requires --name <name>")
            }
            params["name"] = newName
            let resp = try client.sendV2(method: "workspace.group.rename", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "collapse", "expand":
            params["group_id"] = try resolveGroupId(in: rest)
            let resp = try client.sendV2(method: "workspace.group.\(sub)", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "pin", "unpin":
            params["group_id"] = try resolveGroupId(in: rest)
            let resp = try client.sendV2(method: "workspace.group.\(sub)", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "add":
            let (groupOpt, rem0) = parseOption(rest, name: "--group")
            let (wsOpt, _) = parseOption(rem0, name: "--workspace")
            guard let gid = groupOpt, let wsId = wsOpt else {
                throw CLIError(message: "add requires --group <id> --workspace <id>")
            }
            params["group_id"] = gid
            params["workspace_id"] = wsId
            let resp = try client.sendV2(method: "workspace.group.add", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "join":
            let (nameOpt, rem0) = parseOption(rest, name: "--name")
            let (wsOpt, rem1) = parseOption(rem0, name: "--workspace")
            let (_, rem2) = parseOption(rem1, name: "--window")
            let groupName = (nameOpt ?? rem2.first(where: { !$0.hasPrefix("--") }) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupName.isEmpty else {
                throw CLIError(message: "join requires a group name")
            }
            params["name"] = groupName
            // Without --workspace, the caller context above already set the
            // calling terminal's workspace. With --window it did not, and the
            // workspace names its own window anyway.
            if let wsOpt {
                params["workspace_id"] = try normalizeWorkspaceHandle(
                    wsOpt,
                    client: client,
                    windowHandle: params["window_id"] as? String
                ) ?? wsOpt
            }
            guard params["workspace_id"] != nil else {
                throw CLIError(message: params["window_id"] == nil
                    ? "join requires --workspace <id> when run outside a cmux terminal"
                    : "join --window requires --workspace <id>")
            }
            let response = try client.sendV2(method: "workspace.group.join", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
            } else if let group = response["group"] as? [String: Any] {
                let note: String
                if (response["created"] as? Bool) == true {
                    note = " " + String(localized: "cli.workspaceGroup.join.created", defaultValue: "(created)")
                } else if (response["already_member"] as? Bool) == true {
                    note = " " + String(localized: "cli.workspaceGroup.join.alreadyMember", defaultValue: "(already a member)")
                } else {
                    note = ""
                }
                print("OK \(textHandle(group, idFormat: idFormat))\(note)")
            } else {
                print("OK")
            }

        case "remove":
            let (wsOpt, rem0) = parseOption(rest, name: "--workspace")
            // Strip --window before scanning for a positional so a `--window
            // <value>` pair never gets parsed as the workspace id.
            let (_, rem1) = parseOption(rem0, name: "--window")
            guard let wsId = wsOpt ?? rem1.first(where: { !$0.hasPrefix("--") }) else {
                throw CLIError(message: "remove requires --workspace <id>")
            }
            params["workspace_id"] = wsId
            let resp = try client.sendV2(method: "workspace.group.remove", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "set-anchor":
            let (groupOpt, rem0) = parseOption(rest, name: "--group")
            let (wsOpt, _) = parseOption(rem0, name: "--workspace")
            guard let gid = groupOpt, let wsId = wsOpt else {
                throw CLIError(message: "set-anchor requires --group <id> --workspace <id>")
            }
            params["group_id"] = gid
            params["workspace_id"] = wsId
            let resp = try client.sendV2(method: "workspace.group.set_anchor", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "new-workspace":
            let (placementOpt, rem0) = parseOption(rest, name: "--placement")
            params["group_id"] = try resolveGroupId(in: rem0)
            if let placementOpt {
                params["placement"] = placementOpt
            }
            let response = try client.sendV2(method: "workspace.group.new_workspace", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
            } else if let wsId = response["workspace_ref"] as? String {
                print("OK \(wsId)")
            } else {
                print("OK")
            }

        case "set-color":
            let (hexOpt, rem1) = parseOption(rest, name: "--hex")
            // --color is an alias for --hex (mirrors the `custom_color`
            // response field the RPC accepts under the `color` key).
            // Always consume --color so it cannot be mistaken for the group id
            // when both flags are passed; --hex wins.
            let (colorOpt, rem0) = parseOption(rem1, name: "--color")
            params["group_id"] = try resolveGroupId(in: rem0)
            // Treat --hex/--color with no value (or `""`) as a clear.
            params["hex"] = hexOpt ?? colorOpt ?? ""
            let resp = try client.sendV2(method: "workspace.group.set_color", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "set-icon":
            let (symbolOpt, rem1) = parseOption(rest, name: "--symbol")
            // --icon is an alias for --symbol (mirrors the `icon_symbol`
            // response field the RPC accepts under the `icon` key).
            // Always consume --icon so it cannot be mistaken for the group id
            // when both flags are passed; --symbol wins.
            let (iconOpt, rem0) = parseOption(rem1, name: "--icon")
            params["group_id"] = try resolveGroupId(in: rem0)
            params["symbol"] = symbolOpt ?? iconOpt ?? ""
            let resp = try client.sendV2(method: "workspace.group.set_icon", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "move":
            let (toIndexOpt, rem0) = parseOption(rest, name: "--to-index")
            let (beforeOpt, rem1) = parseOption(rem0, name: "--before")
            let (afterOpt, rem2) = parseOption(rem1, name: "--after")
            // Resolve the source group from rem2, which has every
            // move-position flag stripped — otherwise the positional scan
            // could pick up the value of --to-index/--before/--after.
            params["group_id"] = try resolveGroupId(in: rem2)
            if let toIndexOpt {
                guard let n = Int(toIndexOpt) else {
                    throw CLIError(message: "move --to-index must be an integer")
                }
                params["to_index"] = n
            } else if let beforeOpt {
                params["before_group_id"] = beforeOpt
            } else if let afterOpt {
                params["after_group_id"] = afterOpt
            } else {
                throw CLIError(message: "move requires --to-index <n>, --before <group>, or --after <group>")
            }
            let resp = try client.sendV2(method: "workspace.group.move", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "focus":
            params["group_id"] = try resolveGroupId(in: rest)
            let resp = try client.sendV2(method: "workspace.group.focus", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        default:
            throw CLIError(message: "Unknown workspace-group subcommand: \(sub)")
        }
    }

}
