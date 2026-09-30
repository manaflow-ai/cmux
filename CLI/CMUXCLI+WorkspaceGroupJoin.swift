import Foundation

extension CMUXCLI {
    func runWorkspaceGroupJoin(
        rest: [String],
        params: inout [String: Any],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (nameOpt, rem0) = parseOption(rest, name: "--name")
        let (wsOpt, rem1) = parseOption(rem0, name: "--workspace")
        let (_, rem2) = parseOption(rem1, name: "--window")
        let groupName = (nameOpt ?? rem2.first(where: { !$0.hasPrefix("--") }) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !groupName.isEmpty else {
            throw CLIError(message: "join requires a group name")
        }
        params["name"] = groupName
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
    }
}
