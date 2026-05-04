import Foundation

extension CMUXCLI {
    func applyTabActionFocusOption(_ focusOpt: String?, to params: inout [String: Any]) throws {
        guard let focusOpt else { return }
        guard let focus = parseBoolString(focusOpt) else {
            throw CLIError(message: "--focus must be true|false")
        }
        params["focus"] = focus
    }

    func appendCreatedWorkspaceSummaryParts(
        from payload: [String: Any],
        idFormat: CLIIDFormat,
        to summaryParts: inout [String]
    ) {
        guard let id = payload["created_workspace_id"] as? String else { return }
        var createdWorkspacePayload: [String: Any] = ["workspace_id": id]
        if let ref = payload["created_workspace_ref"] as? String {
            createdWorkspacePayload["workspace_ref"] = ref
        }
        if let createdWorkspace = formatHandle(createdWorkspacePayload, kind: "workspace", idFormat: idFormat) {
            summaryParts.append("created_workspace=\(createdWorkspace)")
        }
    }

    func runMoveTabToNewWorkspace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if commandArgs.contains(where: { $0 == "--action" || $0.hasPrefix("--action=") }) {
            throw CLIError(message: "move-tab-to-new-workspace does not accept --action")
        }
        try runTabAction(
            commandArgs: ["--action", "move-to-new-workspace"] + commandArgs,
            client: client,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            windowOverride: windowOverride
        )
    }

    static let moveTabToNewWorkspaceCommandHelp = """
    Usage: cmux move-tab-to-new-workspace [--tab <id|ref|index>] [--surface <id|ref|index>] [--workspace <id|ref|index>] [--title <text>] [--focus <true|false>]

    Move a tab into a newly created workspace in the same window.

    Flags:
      --tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; default: $CMUX_TAB_ID, then $CMUX_SURFACE_ID, then focused tab)
      --surface <id|ref|index>     Alias for --tab
      --workspace <id|ref|index>   Workspace context (default: current/$CMUX_WORKSPACE_ID)
      --title <text>               Optional title for the new workspace
      --focus <true|false>         Focus the new workspace when supported (default: false)

    Example:
      cmux move-tab-to-new-workspace --tab tab:2
      cmux move-tab-to-new-workspace --surface surface:3 --title "build logs"
    """
}
