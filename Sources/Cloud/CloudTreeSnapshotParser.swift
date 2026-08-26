import Foundation

/// Maps a cmux-tui public session snapshot (`session current snapshot --json`) onto the
/// Cloud tree's workspace → terminal shape. Pure and total: unknown keys are ignored,
/// a malformed entry drops that entry, never the machine.
///
/// Snapshot keys (cmux-tui `crates/cmux-tui-core/src/resource_api.rs`,
/// `public_session_snapshot_with_journal_head` / `public_terminal_snapshot`):
/// `workspaces[{id,name,focused}]`, `screens[{id,workspace_id}]`, `panes[{id,screen_id}]`,
/// `tabs[{id,pane_id,content_kind,content_id}]`,
/// `terminals[{id,tab_id,title,cwd?,lifecycle}]`, `agents[{terminal_id,state,source}]`.
struct CloudTreeSnapshotParser: Sendable {
    /// Workspaces with their terminals, in the daemon's order. Terminals whose tab chain
    /// does not resolve to a workspace land in the first workspace so nothing is hidden.
    static func workspaces(fromSnapshot snapshot: [String: Any]) -> [CloudTreeWorkspace] {
        let workspacesRaw = (snapshot["workspaces"] as? [[String: Any]]) ?? []
        let screensRaw = (snapshot["screens"] as? [[String: Any]]) ?? []
        let panesRaw = (snapshot["panes"] as? [[String: Any]]) ?? []
        let tabsRaw = (snapshot["tabs"] as? [[String: Any]]) ?? []
        let terminalsRaw = (snapshot["terminals"] as? [[String: Any]]) ?? []
        let agentsRaw = (snapshot["agents"] as? [[String: Any]]) ?? []

        var workspaceOfScreen: [String: String] = [:]
        for screen in screensRaw {
            if let id = screen["id"] as? String, let workspaceID = screen["workspace_id"] as? String {
                workspaceOfScreen[id] = workspaceID
            }
        }
        var screenOfPane: [String: String] = [:]
        for pane in panesRaw {
            if let id = pane["id"] as? String, let screenID = pane["screen_id"] as? String {
                screenOfPane[id] = screenID
            }
        }
        var paneOfTab: [String: String] = [:]
        for tab in tabsRaw {
            if let id = tab["id"] as? String, let paneID = tab["pane_id"] as? String {
                paneOfTab[id] = paneID
            }
        }
        var agentByTerminal: [String: (state: String, source: String?)] = [:]
        for agent in agentsRaw {
            guard let terminalID = agent["terminal_id"] as? String, let state = agent["state"] as? String else { continue }
            agentByTerminal[terminalID] = (state, agent["source"] as? String)
        }

        var workspaces: [CloudTreeWorkspace] = workspacesRaw.compactMap { raw in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return CloudTreeWorkspace(id: id, name: name, focused: (raw["focused"] as? Bool) ?? false, terminals: [])
        }
        guard !workspaces.isEmpty else { return [] }
        var indexOfWorkspace: [String: Int] = [:]
        for (index, workspace) in workspaces.enumerated() {
            indexOfWorkspace[workspace.id] = index
        }

        for raw in terminalsRaw {
            guard let terminal = terminal(fromSnapshotEntry: raw, agent: agentByTerminal) else { continue }
            let tabIDs = ((raw["tab_ids"] as? [String]) ?? []) + [(raw["tab_id"] as? String) ?? ""]
            let workspaceIndex = tabIDs
                .compactMap { paneOfTab[$0] }
                .compactMap { screenOfPane[$0] }
                .compactMap { workspaceOfScreen[$0] }
                .compactMap { indexOfWorkspace[$0] }
                .first ?? 0
            workspaces[workspaceIndex].terminals.append(terminal)
        }
        return workspaces
    }

    static func terminal(
        fromSnapshotEntry raw: [String: Any],
        agent: [String: (state: String, source: String?)] = [:]
    ) -> CloudTreeTerminal? {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        let lifecycle = CloudTreeTerminalLifecycle(rawValue: (raw["lifecycle"] as? String) ?? "")
            ?? (((raw["running"] as? Bool) ?? false) ? .running : .exited)
        let title = (raw["title"] as? String) ?? ""
        let cwd = (raw["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let agentInfo = agent[id]
        return CloudTreeTerminal(
            id: id,
            title: title.isEmpty ? (cwd ?? "") : title,
            cwd: cwd,
            lifecycle: lifecycle,
            agentState: agentInfo?.state,
            agentSource: agentInfo?.source,
            openSurfaceID: nil
        )
    }

    /// The terminal a `workspace <ws> run` / `tab create terminal` mutation created:
    /// `MutationResult<CreatedTerminalPath>` prints as `{value: {terminal_id, workspace_id, …}}`
    /// under `--json`; a bare `CreatedTerminalPath` is accepted too.
    static func createdTerminal(fromRunResult result: [String: Any]) -> (terminalID: String, workspaceID: String?)? {
        let path = (result["value"] as? [String: Any]) ?? result
        guard let terminalID = path["terminal_id"] as? String, !terminalID.isEmpty else { return nil }
        return (terminalID, path["workspace_id"] as? String)
    }

    /// `remote connect --headless --json` prints `{"event":"connection-snapshot","local_socket":…}`
    /// lines; the first one carries the mux socket path.
    static func localSocket(fromLinkLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["event"] as? String) == "connection-snapshot",
              let socket = object["local_socket"] as? String, !socket.isEmpty else {
            return nil
        }
        return socket
    }

    /// Listening TCP ports from `ss -ltn` / `netstat -ltn` output (what `cmux vm ports` runs).
    static func listeningPorts(fromSocketListing text: String) -> [CloudTreePort] {
        var seen = Set<Int>()
        var ports: [CloudTreePort] = []
        for line in text.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 4 else { continue }
            // `ss`: State Recv-Q Send-Q Local:Port …; `netstat`: Proto Recv-Q Send-Q Local:Port …
            for column in columns.prefix(5) {
                guard let colon = column.lastIndex(of: ":"), let port = Int(column[column.index(after: colon)...]),
                      (1...65535).contains(port), seen.insert(port).inserted else { continue }
                ports.append(CloudTreePort(port: port, label: nil))
                break
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    /// Ports the tree hides: the daemon and desktop transports the machine itself owns.
    static let internalPorts: Set<Int> = [1337, 5901, 6901, 8080]

    static func machineHasDesktop(image: String) -> Bool {
        image.contains("xfce-vnc")
    }
}
