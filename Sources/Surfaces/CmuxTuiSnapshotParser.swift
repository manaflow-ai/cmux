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
    /// Terminal resources in the daemon's workspace order, each carrying every view of it
    /// (`tab_ids` joined through tabs → panes → screens → workspaces). A terminal with no
    /// resolvable view keeps an empty view list: it is alive in the machine's pool, not
    /// attributed to a workspace it is not in.
    static func terminals(fromSnapshot snapshot: [String: Any], machine: SurfaceMachineID) -> [SurfaceResource] {
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

        let workspaces = Self.workspaces(fromSnapshot: snapshot)
        var workspaceByID: [String: SurfaceRemoteWorkspace] = [:]
        for workspace in workspaces { workspaceByID[workspace.id] = workspace }

        var resources: [SurfaceResource] = []
        for raw in terminalsRaw {
            guard var terminal = terminal(fromSnapshotEntry: raw, machine: machine, agents: agentByTerminal) else { continue }
            var tabIDs = (raw["tab_ids"] as? [String]) ?? []
            if tabIDs.isEmpty, let single = raw["tab_id"] as? String, !single.isEmpty {
                tabIDs = [single]
            }
            // cmux-tui keeps a record of a terminal whose process exited after its tab is
            // gone; nothing can open or close it any more (its selector no longer resolves),
            // so it is not a surface. An exited terminal that still has a tab stays listed —
            // that one can be closed.
            if terminal.lifecycle == .exited, tabIDs.isEmpty { continue }
            terminal.remoteViews = tabIDs.compactMap { tabID in
                guard let paneID = paneOfTab[tabID],
                      let screenID = screenOfPane[paneID],
                      let workspaceID = workspaceOfScreen[screenID],
                      let workspace = workspaceByID[workspaceID] else { return nil }
                return SurfaceRemoteView(tabID: tabID, workspace: workspace)
            }
            terminal.remoteWorkspace = terminal.remoteViews?.first?.workspace
            resources.append(terminal)
        }
        // Daemon browsers are workspace tab content just like terminals
        // (`browsers[{id,tab_id,url,title,status}]`) — a workspace holds more than
        // terminals, and the tree shows a browser inside the workspace that views it.
        for raw in (snapshot["browsers"] as? [[String: Any]]) ?? [] {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            let urlString = (raw["url"] as? String) ?? ""
            let title = (raw["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? urlString
            var views: [SurfaceRemoteView] = []
            if let tabID = raw["tab_id"] as? String,
               let paneID = paneOfTab[tabID],
               let screenID = screenOfPane[paneID],
               let workspaceID = workspaceOfScreen[screenID],
               let workspace = workspaceByID[workspaceID] {
                views = [SurfaceRemoteView(tabID: tabID, workspace: workspace)]
            }
            var browser = SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .browser, key: id),
                title: title,
                detail: urlString.isEmpty ? nil : urlString,
                lifecycle: (raw["status"] as? String) == "failed" ? .exited : .running,
                agent: nil,
                remoteWorkspace: views.first?.workspace,
                port: localhostPort(fromURL: urlString),
                url: urlString.isEmpty ? nil : urlString
            )
            browser.remoteViews = views
            resources.append(browser)
        }
        // A display tab (`content_kind: "display"`, `content_id: "display:1"`) is a pointer
        // to the machine's screen: the same display resource the pool lists, with one view
        // per workspace tab that holds it — so a workspace remembers its desktop the way
        // it remembers its terminals and browsers.
        var displayViews: [String: [SurfaceRemoteView]] = [:]
        var displayOrder: [String] = []
        for tab in tabsRaw {
            guard (tab["content_kind"] as? String) == "display",
                  let contentID = tab["content_id"] as? String, !contentID.isEmpty,
                  let tabID = tab["id"] as? String,
                  let paneID = paneOfTab[tabID],
                  let screenID = screenOfPane[paneID],
                  let workspaceID = workspaceOfScreen[screenID],
                  let workspace = workspaceByID[workspaceID] else { continue }
            if displayViews[contentID] == nil { displayOrder.append(contentID) }
            displayViews[contentID, default: []].append(SurfaceRemoteView(tabID: tabID, workspace: workspace))
        }
        for contentID in displayOrder {
            var display = Self.display(machine: machine, key: contentID)
            display.remoteViews = displayViews[contentID]
            display.remoteWorkspace = displayViews[contentID]?.first?.workspace
            resources.append(display)
        }
        // Workspace order first; zero-view terminals (the pool) trail.
        return resources.sorted { lhs, rhs in
            let li = lhs.remoteWorkspace?.index ?? Int.max, ri = rhs.remoteWorkspace?.index ?? Int.max
            return li != ri ? li < ri : false
        }
    }

    /// The machine-local port a daemon browser's URL points at, when it does —
    /// `http://localhost:3000/...` and equivalents. A remote browser projects through the
    /// machine's port preview, so only localhost URLs are projectable today.
    static func localhostPort(fromURL urlString: String) -> Int? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        guard ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) else { return nil }
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// The tab each terminal currently sits in (`terminals[].tab_ids`/`tab_id`), so an
    /// exited terminal can be closed through its tab when its own selector is gone.
    static func tabByTerminal(fromSnapshot snapshot: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for raw in (snapshot["terminals"] as? [[String: Any]]) ?? [] {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            let tabIDs = ((raw["tab_ids"] as? [String]) ?? []) + [(raw["tab_id"] as? String) ?? ""]
            if let tab = tabIDs.first(where: { !$0.isEmpty }) { result[id] = tab }
        }
        // A display pointer has no process to end: closing it means closing its tab.
        for tab in (snapshot["tabs"] as? [[String: Any]]) ?? [] {
            guard (tab["content_kind"] as? String) == "display",
                  let contentID = tab["content_id"] as? String, !contentID.isEmpty,
                  let tabID = tab["id"] as? String, !tabID.isEmpty, result[contentID] == nil else { continue }
            result[contentID] = tabID
        }
        return result
    }

    /// The workspace and first terminal a `workspace create` mutation made
    /// (`{value: {workspace_id, terminal_id, …}}`).
    static func createdWorkspaceTerminal(fromResult result: [String: Any]) -> (workspaceID: String, terminalID: String?)? {
        let path = (result["value"] as? [String: Any]) ?? result
        guard let workspaceID = ((path["workspace_id"] as? String) ?? (path["id"] as? String)), !workspaceID.isEmpty else { return nil }
        return (workspaceID, (path["terminal_id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The daemon's workspaces, in its order — including empty ones, which have no
    /// terminal to derive them from.
    static func workspaces(fromSnapshot snapshot: [String: Any]) -> [SurfaceRemoteWorkspace] {
        let workspacesRaw = (snapshot["workspaces"] as? [[String: Any]]) ?? []
        return workspacesRaw.enumerated().compactMap { index, raw in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            let name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return SurfaceRemoteWorkspace(id: id, name: name, index: index, focused: (raw["focused"] as? Bool) ?? false)
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

    /// The VNC display of a desktop machine (`display:1`; the key is the daemon's content id
    /// once a workspace points at it).
    static func display(machine: SurfaceMachineID, key: String = "display:1") -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .display, key: key),
            title: "Desktop",
            detail: "noVNC",
            lifecycle: .running,
            agent: nil,
            remoteWorkspace: nil,
            port: desktopPort,
            url: nil
        )
    }

    /// The machine's display list after a snapshot: a display the daemon's workspaces point
    /// at (carrying its views) replaces the bare pool entry of the same id; every other
    /// resource passes through. Pure, so the provider's refresh stays a straight line.
    static func mergingDisplays(pool: [SurfaceResource], parsed: [SurfaceResource]) -> [SurfaceResource] {
        let pointed = Set(parsed.filter { $0.kind == .display }.map(\.id))
        return pool.filter { !($0.kind == .display && pointed.contains($0.id)) } + parsed
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
