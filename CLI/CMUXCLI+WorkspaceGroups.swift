import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Workspace namespace and group commands
extension CMUXCLI {
    /// Top-level `cmux workspace <subcommand>` namespace. Dispatches to the
    /// same v2 socket methods that legacy verbs use (`new-workspace`,
    /// `list-workspaces`, etc.) so behavior matches. Legacy verbs keep working
    /// unchanged for backwards compatibility.
    func runWorkspaceNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let sub = commandArgs.first?.lowercased() else {
            throw CLIError(message: "workspace requires a subcommand. Try: list, create, close, rename, select, group")
        }
        let rest = Array(commandArgs.dropFirst())
        switch sub {
        case "group":
            try runWorkspaceGroup(
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        case "list":
            try runWorkspaceListCommand(
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride
            )
        case "create":
            try runWorkspaceCreateCommand(
                commandName: "workspace create",
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride,
                honorJSONOutput: true
            )
        case "close":
            try runWorkspaceCloseCommand(
                commandName: "workspace close",
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride,
                requireWorkspaceFlag: false
            )
        case "rename":
            try runWorkspaceRenameCommand(
                commandName: "workspace rename",
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride,
                mode: .namespace
            )
        case "select":
            try runWorkspaceSelectCommand(
                commandName: "workspace select",
                commandArgs: rest,
                client: client,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                windowOverride: windowOverride,
                requireWorkspaceFlag: false
            )
        default:
            throw CLIError(message: "Unknown workspace subcommand: \(sub). Try: list, create, close, rename, select, group")
        }
    }

    /// Emit a `cmux workspace-group` mutation response: JSON when --json,
    /// otherwise a compact `OK`. Centralized so every mutating subcommand
    /// honors --json the same way the list/create paths do.
    private func printWorkspaceGroupResponse(
        _ response: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(response, mode: idFormat)))
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
        FileHandle.standardError.write(Data(
            "cmux: '\(legacy)' is now an alias for '\(replacement)'. The legacy form keeps working indefinitely; set CMUX_QUIET=1 to silence this notice.\n".utf8
        ))
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
            throw CLIError(message: "workspace-group requires a subcommand. Try: list, create, ungroup, delete, rename, collapse, expand, pin, unpin, add, remove, set-anchor, new-workspace, set-color, set-icon, move, focus")
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
            let (_, rem3) = parseOption(rem2, name: "--window")
            // Use the remainder AFTER every named option is stripped so the
            // positional name lookup can't pick up --from/--window values.
            let resolvedName = nameOpt ?? rem3.first(where: { !$0.hasPrefix("--") }) ?? ""
            params["name"] = resolvedName
            if let cwdOpt { params["cwd"] = resolvePath(cwdOpt) }
            if let fromOpt {
                let ids = fromOpt.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                params["child_workspace_ids"] = ids
            }
            let response = try client.sendV2(method: "workspace.group.create", params: params)
            if jsonOutput {
                print(jsonString(formatIDs(response, mode: idFormat)))
            } else if let group = response["group"] as? [String: Any] {
                print("OK \(textHandle(group, idFormat: idFormat))")
            } else {
                print("OK")
            }

        case "ungroup":
            params["group_id"] = try resolveGroupId(in: rest)
            let resp = try client.sendV2(method: "workspace.group.ungroup", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "delete":
            // Destructive: closes every workspace inside the group. Use
            // `ungroup` instead if you want to keep the workspaces.
            params["group_id"] = try resolveGroupId(in: rest)
            let resp = try client.sendV2(method: "workspace.group.delete", params: params)
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
            let (hexOpt, rem0) = parseOption(rest, name: "--hex")
            params["group_id"] = try resolveGroupId(in: rem0)
            // Treat --hex with no value (or `--hex ""`) as a clear.
            params["hex"] = hexOpt ?? ""
            let resp = try client.sendV2(method: "workspace.group.set_color", params: params)
            printWorkspaceGroupResponse(resp, jsonOutput: jsonOutput, idFormat: idFormat)

        case "set-icon":
            let (symbolOpt, rem0) = parseOption(rest, name: "--symbol")
            params["group_id"] = try resolveGroupId(in: rem0)
            params["symbol"] = symbolOpt ?? ""
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

    func runRenameTab(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (tabOpt, rem1) = parseOption(rem0, name: "--tab")
        let (surfaceOpt, rem2) = parseOption(rem1, name: "--surface")
        let (titleOpt, rem3) = parseOption(rem2, name: "--title")
        let (windowOpt, rem4) = parseOption(rem3, name: "--window")

        if rem4.contains("--action") {
            throw CLIError(message: "rename-tab does not accept --action (it always performs rename)")
        }
        if let unknown = rem4.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            throw CLIError(message: "rename-tab: unknown flag '\(unknown)'")
        }

        let inferredTitle = rem4
            .dropFirst(rem4.first == "--" ? 1 : 0)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleOpt ?? (inferredTitle.isEmpty ? nil : inferredTitle))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let title, !title.isEmpty else {
            throw CLIError(message: "rename-tab requires a title")
        }

        var forwarded: [String] = ["--action", "rename", "--title", title]
        if let workspaceOpt {
            forwarded += ["--workspace", workspaceOpt]
        }
        if let tabOpt {
            forwarded += ["--tab", tabOpt]
        } else if let surfaceOpt {
            forwarded += ["--surface", surfaceOpt]
        }
        if let windowOpt {
            forwarded += ["--window", windowOpt]
        }

        try runTabAction(
            commandArgs: forwarded,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
    }
}
