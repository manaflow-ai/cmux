import Foundation

extension AgentCLIJobReceipt: Encodable {
    private enum OutputKeys: String, CodingKey { case machine, session, cli, path, revision, replayed }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: OutputKeys.self)
        try fields.encode(machine, forKey: .machine)
        try fields.encode(session, forKey: .session)
        try fields.encode(cli.rawValue, forKey: .cli)
        try fields.encode(path, forKey: .path)
        try fields.encode(String(revision), forKey: .revision)
        try fields.encode(replayed, forKey: .replayed)
    }
}

extension AgentCLIJobReceipt.Path: Encodable {
    private enum OutputKeys: String, CodingKey {
        case kind, workspaceID = "workspace_id", screenID = "screen_id"
        case paneID = "pane_id", tabID = "tab_id", terminalID = "terminal_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: OutputKeys.self)
        try fields.encode("terminal", forKey: .kind)
        try fields.encode(workspaceID, forKey: .workspaceID)
        try fields.encode(screenID, forKey: .screenID)
        try fields.encode(paneID, forKey: .paneID)
        try fields.encode(tabID, forKey: .tabID)
        try fields.encode(terminalID, forKey: .terminalID)
    }
}
