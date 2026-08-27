import Foundation

/// Maps a cmux-tui public session snapshot (`session current snapshot --json`) onto
/// ``SurfaceResource`` values for one cloud machine. Pure and total: unknown keys are
/// ignored, a malformed entry drops that entry, never the machine.
///
/// Snapshot keys (cmux-tui `crates/cmux-tui-core/src/resource_api.rs`,
/// `public_session_snapshot_with_journal_head` / `public_terminal_snapshot`):
/// `workspaces[{id,name,focused}]`, `screens[{id,workspace_id}]`, `panes[{id,screen_id}]`,
/// `tabs[{id,pane_id,content_kind,content_id}]`,
/// `terminals[{id,tab_id,title,cwd?,lifecycle}]`, `agents[{terminal_id,state,source}]`.
struct CmuxTuiSnapshotParser: Sendable {
    /// Terminal resources in the daemon's workspace order. A terminal whose tab chain does
    /// not resolve to a workspace is attributed to the first workspace so nothing is hidden.
    static func terminals(fromSnapshot snapshot: [String: Any], machine: SurfaceMachineID) -> [SurfaceResource] {
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
        var agentByTerminal: [String: SurfaceAgentBadge] = [:]
        for agent in agentsRaw {
            guard let terminalID = agent["terminal_id"] as? String, let state = agent["state"] as? String else { continue }
            agentByTerminal[terminalID] = SurfaceAgentBadge(state: state, source: agent["source"] as? String)
        }

        let workspaces: [SurfaceRemoteWorkspace] = workspacesRaw.enumerated().compactMap { index, raw in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return SurfaceRemoteWorkspace(id: id, name: name, index: index, focused: (raw["focused"] as? Bool) ?? false)
        }
        guard !workspaces.isEmpty else { return [] }
        var workspaceByID: [String: SurfaceRemoteWorkspace] = [:]
        for workspace in workspaces { workspaceByID[workspace.id] = workspace }

        var resources: [SurfaceResource] = []
        for raw in terminalsRaw {
            guard var terminal = terminal(fromSnapshotEntry: raw, machine: machine, agents: agentByTerminal) else { continue }
            let tabIDs = ((raw["tab_ids"] as? [String]) ?? []) + [(raw["tab_id"] as? String) ?? ""]
            terminal.remoteWorkspace = tabIDs
                .compactMap { paneOfTab[$0] }
                .compactMap { screenOfPane[$0] }
                .compactMap { workspaceOfScreen[$0] }
                .compactMap { workspaceByID[$0] }
                .first ?? workspaces[0]
            resources.append(terminal)
        }
        return resources.sorted { lhs, rhs in
            let li = lhs.remoteWorkspace?.index ?? 0, ri = rhs.remoteWorkspace?.index ?? 0
            return li != ri ? li < ri : false
        }
    }

    static func terminal(
        fromSnapshotEntry raw: [String: Any],
        machine: SurfaceMachineID,
        agents: [String: SurfaceAgentBadge] = [:]
    ) -> SurfaceResource? {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        let lifecycle = SurfaceLifecycle(rawValue: (raw["lifecycle"] as? String) ?? "")
            ?? (((raw["running"] as? Bool) ?? false) ? .running : .exited)
        let title = (raw["title"] as? String) ?? ""
        let cwd = (raw["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .terminal, key: id),
            title: title,
            detail: cwd,
            lifecycle: lifecycle,
            agent: agents[id],
            remoteWorkspace: nil,
            port: nil,
            url: nil
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

    /// The workspace a `workspace create` mutation created.
    static func createdWorkspace(fromResult result: [String: Any]) -> String? {
        let path = (result["value"] as? [String: Any]) ?? result
        let id = (path["workspace_id"] as? String) ?? (path["id"] as? String)
        return id.flatMap { $0.isEmpty ? nil : $0 }
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
    static func listeningPorts(fromSocketListing text: String) -> [Int] {
        var seen = Set<Int>()
        var ports: [Int] = []
        for line in text.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard columns.count >= 4 else { continue }
            // `ss`: State Recv-Q Send-Q Local:Port …; `netstat`: Proto Recv-Q Send-Q Local:Port …
            for column in columns.prefix(5) {
                guard let colon = column.lastIndex(of: ":"), let port = Int(column[column.index(after: colon)...]),
                      (1...65535).contains(port), seen.insert(port).inserted else { continue }
                ports.append(port)
                break
            }
        }
        return ports.sorted()
    }

    /// Ports the tree hides: the daemon and desktop transports the machine itself owns.
    static let internalPorts: Set<Int> = [1337, 5901, 6901, 8080]

    static let desktopPort = 6901

    static func machineHasDesktop(image: String) -> Bool {
        image.contains("xfce-vnc") || image.contains("cmux-devbox")
    }

    /// The VNC screen of a desktop machine.
    static func screen(machine: SurfaceMachineID) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .screen, key: "display:1"),
            title: "Desktop",
            detail: "noVNC",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: desktopPort,
            url: nil
        )
    }

    /// A forwarded port, shown as a browser resource.
    static func portBrowser(machine: SurfaceMachineID, port: Int) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: "port:\(port)"),
            title: ":\(port)",
            detail: nil,
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: port,
            url: nil
        )
    }

    /// The noVNC page recipe `cmux vm desktop` uses: auto-connect, follow the pane's size,
    /// reconnect after a sleep.
    static func desktopURL(openURL: String) -> String {
        openURL + "&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
    }
}
