import Foundation

/// Discovers the full session tree on one host by running one POSIX-sh
/// probe script: locally via `/bin/sh -s`, remotely via `ssh <dest> sh -s`
/// (one round trip per host, script on stdin).
///
/// Line protocol (tab-separated; every stanza tolerates a missing tool):
///   `S <tool> <session> <state> <detail>`                       session
///   `TW <session> <window_id> <index> <name>`                   tmux window
///   `TP <session> <window_id> <pane_id> <active> <command>`     tmux pane
///   `J <tool> <session> <kind> <one-line-json>`                 cmux-tui / herdr
enum HarborSessionProbe {
    static let script = #"""
    #!/bin/sh
    emit() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

    if command -v tmux >/dev/null 2>&1; then
      tmux ls -F '#{session_name}	#{?session_attached,attached,detached}	#{session_windows}w' 2>/dev/null |
      while IFS='	' read -r n st d; do emit S tmux "$n" "$st" "$d"; done
      tmux list-windows -a -F 'TW	#{session_name}	#{window_id}	#{window_index}	#{window_name}' 2>/dev/null
      tmux list-panes -a -F 'TP	#{session_name}	#{window_id}	#{pane_id}	#{pane_active}	#{pane_current_command}' 2>/dev/null
    fi

    if command -v zellij >/dev/null 2>&1; then
      zellij list-sessions --no-formatting 2>/dev/null |
      while read -r n rest; do
        case "$rest" in *EXITED*) st=exited;; *) st=detached;; esac
        [ -n "$n" ] && emit S zellij "$n" "$st" ""
      done
    fi

    if command -v screen >/dev/null 2>&1; then
      screen -ls 2>/dev/null | sed -n 's/^[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*(\(.*\))/\1	\2/p' |
      while IFS='	' read -r n st; do
        case "$st" in *ttached*) s=attached;; *) s=detached;; esac
        emit S screen "$n" "$s" ""
      done
    fi

    if command -v zmx >/dev/null 2>&1; then
      zmx list 2>/dev/null | while read -r line; do
        n=""; c=""
        for kv in $line; do
          case "$kv" in name=*) n=${kv#name=};; clients=*) c=${kv#clients=};; esac
        done
        [ -n "$n" ] || continue
        if [ "${c:-0}" -gt 0 ] 2>/dev/null; then s=attached; else s=detached; fi
        emit S zmx "$n" "$s" ""
      done
    fi

    if command -v herdr >/dev/null 2>&1; then
      herdr session list 2>/dev/null | sed '1d' |
      while read -r n st dir _; do
        [ -n "$n" ] || continue
        emit S herdr "$n" "$st" "$dir"
        if [ "$st" = "running" ]; then
          for kind in "workspace list" "tab list" "pane list" "agent list"; do
            j=$(herdr --session "$n" $kind 2>/dev/null | head -1)
            [ -n "$j" ] && printf 'J\therdr\t%s\t%s\t%s\n' "$n" "$(echo "$kind" | tr ' ' -)" "$j"
          done
        fi
      done
    fi

    CT="${CMUX_HARBOR_TUI_BINARY:-}"
    if [ -n "$CT" ] && [ ! -x "$CT" ]; then CT=""; fi
    if [ -z "$CT" ] && command -v cmux-tui >/dev/null 2>&1; then CT=cmux-tui
    elif [ -z "$CT" ] && [ -x "$HOME/.local/bin/cmux-tui" ]; then CT="$HOME/.local/bin/cmux-tui"; fi
    if [ -n "$CT" ]; then
      for d in "${TMPDIR:-/tmp}/cmux-tui-$(id -u)" "/tmp/cmux-tui-$(id -u)"; do
        [ -d "$d" ] || continue
        for s in "$d"/*.sock; do
          [ -S "$s" ] || continue
          n=$(basename "$s" .sock)
          "$CT" --socket "$s" server status 2>/dev/null | grep -q "is running" || continue
          emit S cmux-tui "$n" running "$s"
          for kind in "workspace list" "tab list" "screen list" "terminal list"; do
            j=$("$CT" --socket "$s" --json $kind 2>/dev/null | head -1)
            [ -n "$j" ] && printf 'J\tcmux-tui\t%s\t%s\t%s\n' "$n" "$(echo "$kind" | tr ' ' -)" "$j"
          done
        done
      done
    fi
    exit 0
    """#

    enum ProbeError: Error, Equatable {
        case launchFailed
        case timedOut
        case failed(exitCode: Int32, stderr: String)
    }

    /// Runs the probe for one host off the main actor and parses the tree.
    /// Discovery uses `BatchMode=yes`, so an SSH host that needs interactive
    /// auth reports as unreachable here.
    static func discoverSessions(
        host: HarborHostRef,
        ownSessionName: String?,
        timeout: TimeInterval = 10
    ) async throws -> [HarborSessionInfo] {
        let (executable, arguments): (String, [String])
        switch host {
        case .local:
            (executable, arguments) = ("/bin/sh", ["-s"])
        case .ssh(let destination):
            (executable, arguments) = ("/usr/bin/ssh", [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=6",
                "--", destination,
                "sh -s",
            ])
        }
        let environment: [String: String]?
        if host.isLocal {
            environment = ["CMUX_HARBOR_TUI_BINARY": TuiTerminalAttachBridge.configuredBinaryPath]
        } else {
            environment = nil
        }
        let output = try await runScript(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            environment: environment
        )
        return HarborProbeOutputParser.sessions(fromProbeOutput: output, host: host, ownSessionName: ownSessionName)
    }

    /// Compatibility overload for the original session-only panel. Keep the
    /// host probe as the single source of truth, then flatten one session row
    /// per discovered tree root.
    static func discoverSessions(
        source: HarborSource,
        ownSessionName: String?,
        timeout: TimeInterval = 10
    ) async throws -> [HarborSession] {
        let infos = try await discoverSessions(
            host: source,
            ownSessionName: ownSessionName,
            timeout: timeout
        )
        return infos.map { info in
            HarborSession(
                source: source,
                tool: info.tool,
                name: info.name,
                state: info.state,
                detail: info.detail
            )
        }
    }

    private static func runScript(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try runScriptBlocking(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        environment: environment
                    )
                })
            }
        }
    }

    private static func runScriptBlocking(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw ProbeError.launchFailed
        }
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try? stdin.fileHandleForWriting.close()

        // Drain both pipes off-thread so a chatty probe cannot deadlock on a
        // full pipe buffer before the termination handler fires.
        let outputBox = HarborProbeOutputBox()
        let drained = DispatchSemaphore(value: 0)
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.storeStdout(stdoutHandle.readDataToEndOfFile())
            drained.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.storeStderr(stderrHandle.readDataToEndOfFile())
            drained.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw ProbeError.timedOut
        }
        _ = drained.wait(timeout: .now() + 2)
        _ = drained.wait(timeout: .now() + 2)
        guard process.terminationStatus == 0 else {
            throw ProbeError.failed(
                exitCode: process.terminationStatus,
                stderr: String(data: outputBox.takeStderr(), encoding: .utf8) ?? ""
            )
        }
        return String(data: outputBox.takeStdout(), encoding: .utf8) ?? ""
    }
}

/// Assembles probe lines into per-session trees.
enum HarborProbeOutputParser {
    /// Compatibility flattening used by the first Harbor panel revision.
    static func sessions(
        fromProbeOutput output: String,
        source: HarborSource,
        ownSessionName: String? = nil
    ) -> [HarborSession] {
        sessions(fromProbeOutput: output, host: source, ownSessionName: ownSessionName).map { info in
            HarborSession(
                source: source,
                tool: info.tool,
                name: info.name,
                state: info.state,
                detail: info.detail
            )
        }
    }

    static func sessions(
        fromProbeOutput output: String,
        host: HarborHostRef,
        ownSessionName: String? = nil
    ) -> [HarborSessionInfo] {
        var sessionOrder: [String] = []
        var sessions: [String: (tool: HarborTool, state: HarborSessionState, detail: String)] = [:]
        var tmuxWindows: [String: [(id: Int, index: Int, name: String)]] = [:]
        var tmuxPanes: [String: [Int: [(paneID: Int, active: Bool, command: String)]]] = [:]
        var jsonLines: [String: [String: Data]] = [:]

        func sessionKey(_ tool: HarborTool, _ name: String) -> String { "\(tool.rawValue)/\(name)" }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "S":
                guard fields.count >= 4, let tool = HarborTool(rawValue: fields[1]) else { continue }
                let name = fields[2]
                guard !name.isEmpty else { continue }
                if tool == .cmuxTui,
                   HarborSessionInfo.isCmuxInfrastructureSession(name: name, ownSessionName: ownSessionName) {
                    continue
                }
                let key = sessionKey(tool, name)
                guard sessions[key] == nil else { continue }
                sessions[key] = (
                    tool,
                    HarborSessionState(rawValue: fields[3]) ?? .unknown,
                    fields.count > 4 ? fields[4] : ""
                )
                sessionOrder.append(key)
            case "TW":
                guard fields.count >= 5,
                      let windowID = tmuxID(fields[2], prefix: "@"),
                      let index = Int(fields[3]) else { continue }
                tmuxWindows[fields[1], default: []].append((windowID, index, fields[4]))
            case "TP":
                guard fields.count >= 4,
                      let windowID = tmuxID(fields[2], prefix: "@"),
                      let paneID = tmuxID(fields[3], prefix: "%") else { continue }
                let active = fields.count > 4 && fields[4].hasPrefix("1")
                let command = fields.count > 4
                    ? fields[4].split(separator: "\t").dropFirst().first.map(String.init) ?? ""
                    : ""
                tmuxPanes[fields[1], default: [:]][windowID, default: []]
                    .append((paneID, active, command))
            case "J":
                guard fields.count >= 5, let tool = HarborTool(rawValue: fields[1]) else { continue }
                jsonLines[sessionKey(tool, fields[2]), default: [:]][fields[3]] = Data(fields[4].utf8)
            default:
                // Keep accepting the four-column protocol emitted by the
                // first Harbor build. This is useful for persisted probe
                // fixtures and makes the parser tolerant of an older helper
                // script on a remote host.
                guard fields.count >= 3,
                      let rawTool = fields.first,
                      let tool = HarborTool(rawValue: rawTool) else { continue }
                let name = fields[1]
                guard !name.isEmpty else { continue }
                if tool == .cmuxTui,
                   HarborSessionInfo.isCmuxInfrastructureSession(name: name, ownSessionName: ownSessionName) {
                    continue
                }
                let key = sessionKey(tool, name)
                guard sessions[key] == nil else { continue }
                sessions[key] = (
                    tool,
                    HarborSessionState(rawValue: fields[2]) ?? .unknown,
                    fields.count > 3 ? fields[3] : ""
                )
                sessionOrder.append(key)
            }
        }

        return sessionOrder.compactMap { key -> HarborSessionInfo? in
            guard let base = sessions[key] else { return nil }
            let name = String(key.dropFirst(base.tool.rawValue.count + 1))
            switch base.tool {
            case .tmux:
                return tmuxSessionInfo(
                    host: host, name: name, state: base.state, detail: base.detail,
                    windows: tmuxWindows[name] ?? [], panes: tmuxPanes[name] ?? [:]
                )
            case .cmuxTui:
                return tuiSessionInfo(
                    host: host, name: name, state: base.state, socketPath: base.detail,
                    json: jsonLines[key] ?? [:]
                )
            case .herdr:
                return herdrSessionInfo(
                    host: host, name: name, state: base.state, detail: base.detail,
                    json: jsonLines[key] ?? [:]
                )
            case .zellij, .screen, .zmx:
                return HarborSessionInfo(
                    tool: base.tool, name: name, state: base.state, detail: base.detail,
                    windows: [], looseTerminals: []
                )
            }
        }
    }

    private static func tmuxID(_ raw: String, prefix: String) -> Int? {
        raw.hasPrefix(prefix) ? Int(raw.dropFirst()) : Int(raw)
    }

    private static func tmuxSessionInfo(
        host: HarborHostRef,
        name: String,
        state: HarborSessionState,
        detail: String,
        windows: [(id: Int, index: Int, name: String)],
        panes: [Int: [(paneID: Int, active: Bool, command: String)]]
    ) -> HarborSessionInfo {
        let windowInfos = windows.map { window -> HarborWindowInfo in
            let terminals = (panes[window.id] ?? []).map { pane in
                HarborTerminalInfo(
                    leaf: .tmuxPane(host: host, sessionName: name, windowID: window.id, paneID: pane.paneID),
                    shortID: "%\(pane.paneID)",
                    title: pane.command,
                    isActive: pane.active,
                    stableID: "%\(pane.paneID)"
                )
            }
            return HarborWindowInfo(
                id: "@\(window.id)",
                label: "\(window.index): \(window.name)",
                terminals: terminals
            )
        }
        return HarborSessionInfo(
            tool: .tmux, name: name, state: state, detail: detail,
            windows: windowInfos, looseTerminals: []
        )
    }

    private static func tuiSessionInfo(
        host: HarborHostRef,
        name: String,
        state: HarborSessionState,
        socketPath: String,
        json: [String: Data]
    ) -> HarborSessionInfo {
        struct TuiWorkspace: Decodable {
            let id: String
            let name: String?
            let index: Int?
        }
        struct TuiTab: Decodable {
            let id: String?
            let tab_id: String?
            let workspace_id: String?
            let focused: Bool?
        }
        struct TuiTerminal: Decodable {
            let id: String
            let title: String?
            let tab_id: String?
            let cwd: String?
            let lifecycle: String?
            let running: Bool?
        }
        let decoder = JSONDecoder()
        let workspaces = (json["workspace-list"].flatMap { try? decoder.decode([TuiWorkspace].self, from: $0) }) ?? []
        let tabs = (json["tab-list"].flatMap { try? decoder.decode([TuiTab].self, from: $0) }) ?? []
        let terminals = (json["terminal-list"].flatMap { try? decoder.decode([TuiTerminal].self, from: $0) }) ?? []

        var workspaceByTab: [String: String] = [:]
        var focusedTabs = Set<String>()
        for tab in tabs {
            if let tabID = tab.tab_id ?? tab.id {
                if let workspaceID = tab.workspace_id { workspaceByTab[tabID] = workspaceID }
                if tab.focused == true { focusedTabs.insert(tabID) }
            }
        }
        if let screenData = json["screen-list"],
           let screens = try? JSONSerialization.jsonObject(with: screenData) as? [[String: Any]] {
            for screen in screens {
                guard let workspaceID = screen["workspace_id"] as? String,
                      let layout = screen["layout"] else { continue }
                collectTabWorkspaceIDs(
                    from: layout,
                    workspaceID: workspaceID,
                    into: &workspaceByTab,
                    focusedTabs: &focusedTabs
                )
            }
        }
        let localSocketPath: String? = host.isLocal ? socketPath : nil

        func terminalInfo(_ terminal: TuiTerminal) -> HarborTerminalInfo {
            HarborTerminalInfo(
                leaf: .tuiTerminal(
                    host: host, sessionName: name,
                    socketPath: localSocketPath, terminalID: terminal.id
                ),
                shortID: String(terminal.id.prefix(12)),
                title: terminal.title ?? "",
                isActive: terminal.tab_id.map(focusedTabs.contains) ?? false,
                cwd: terminal.cwd,
                stableID: terminal.id
            )
        }

        var terminalsByWorkspace: [String: [HarborTerminalInfo]] = [:]
        var loose: [HarborTerminalInfo] = []
        for terminal in terminals {
            // `terminal list` includes durable history. Harbor is an attach
            // catalog, so exited terminals must not become draggable leaves
            // that can only fail when opened.
            if terminal.running == false || terminal.lifecycle == "exited" {
                continue
            }
            if let tabID = terminal.tab_id, let workspaceID = workspaceByTab[tabID] {
                terminalsByWorkspace[workspaceID, default: []].append(terminalInfo(terminal))
            } else {
                loose.append(terminalInfo(terminal))
            }
        }
        let windows = workspaces.compactMap { workspace -> HarborWindowInfo? in
            let terminals = terminalsByWorkspace.removeValue(forKey: workspace.id) ?? []
            guard !terminals.isEmpty else { return nil }
            return HarborWindowInfo(
                id: workspace.id,
                label: workspace.name ?? workspace.index.map(String.init) ?? workspace.id,
                terminals: terminals
            )
        }
        // Terminals whose workspace was not listed still show, ungrouped.
        loose.append(contentsOf: terminalsByWorkspace.values.flatMap { $0 })
        return HarborSessionInfo(
            tool: .cmuxTui, name: name, state: state, detail: socketPath,
            windows: windows, looseTerminals: loose
        )
    }

    /// Walks the JSON layout emitted by `cmux-tui screen list`. The layout
    /// schema has changed node names over time, so this deliberately keys off
    /// the stable `tab_ids` and `active_tab_id` fields instead of decoding the
    /// entire recursive enum.
    private static func collectTabWorkspaceIDs(
        from value: Any,
        workspaceID: String,
        into workspaceByTab: inout [String: String],
        focusedTabs: inout Set<String>
    ) {
        if let dictionary = value as? [String: Any] {
            if let tabID = dictionary["active_tab_id"] as? String {
                workspaceByTab[tabID] = workspaceID
                if dictionary["focused"] as? Bool == true { focusedTabs.insert(tabID) }
            }
            if let tabIDs = dictionary["tab_ids"] as? [String] {
                for tabID in tabIDs { workspaceByTab[tabID] = workspaceID }
            }
            for child in dictionary.values {
                collectTabWorkspaceIDs(
                    from: child,
                    workspaceID: workspaceID,
                    into: &workspaceByTab,
                    focusedTabs: &focusedTabs
                )
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectTabWorkspaceIDs(
                    from: child,
                    workspaceID: workspaceID,
                    into: &workspaceByTab,
                    focusedTabs: &focusedTabs
                )
            }
        }
    }

    private static func herdrSessionInfo(
        host: HarborHostRef,
        name: String,
        state: HarborSessionState,
        detail: String,
        json: [String: Data]
    ) -> HarborSessionInfo {
        struct Envelope<T: Decodable>: Decodable { let result: T }
        struct WorkspaceList: Decodable {
            let workspaces: [Item]
            struct Item: Decodable {
                let workspace_id: String
                let label: String?
                let number: Int?
            }
        }
        struct PaneList: Decodable {
            let panes: [Item]?
            struct Item: Decodable {
                let pane_id: String?
                let workspace_id: String?
                let terminal_id: String?
                let terminal_title: String?
                let cwd: String?
                let agent: String?
                let display_agent: String?
                let name: String?
                let title: String?
                let agent_session: AgentSession?
                let agent_status: String?
                let message: String?
                let priority: Int?
                let focused: Bool?
            }
        }
        struct AgentList: Decodable {
            let agents: [Item]?
            struct Item: Decodable {
                let agent: String?
                let display_agent: String?
                let name: String?
                let title: String?
                let agent_session: AgentSession?
                let agent_status: String?
                let pane_id: String?
                let message: String?
                let priority: Int?
            }
        }
        struct AgentSession: Decodable {
            let agent: String?
            let kind: String?
            let source: String?
            let value: String?
        }
        let decoder = JSONDecoder()
        let workspaces = (json["workspace-list"].flatMap { try? decoder.decode(Envelope<WorkspaceList>.self, from: $0) })?
            .result.workspaces ?? []
        let panes = (json["pane-list"].flatMap { try? decoder.decode(Envelope<PaneList>.self, from: $0) })?
            .result.panes ?? []
        let agents = (json["agent-list"].flatMap { try? decoder.decode(Envelope<AgentList>.self, from: $0) })?
            .result.agents ?? []

        var panesByWorkspace: [String: [HarborTerminalInfo]] = [:]
        for pane in panes {
            guard let paneID = pane.pane_id else { continue }
            let listedAgent = agents.first(where: { $0.pane_id == paneID })
            let paneKind = pane.agent ?? pane.agent_session?.agent
            let listedKind = listedAgent?.agent ?? listedAgent?.agent_session?.agent
            let kind = paneKind ?? listedKind ?? pane.display_agent ?? listedAgent?.display_agent
            let paneName = pane.name ?? pane.display_agent ?? pane.agent_session?.value
            let listedName = listedAgent?.name
                ?? listedAgent?.display_agent
                ?? listedAgent?.agent_session?.value
            let agentName = paneName ?? listedName ?? pane.title ?? listedAgent?.title
            let agentState = pane.agent_status ?? listedAgent?.agent_status
            let agentMessage = pane.message ?? listedAgent?.message
            let agentPriority = pane.priority ?? listedAgent?.priority
            let agent = makeAgentInfo(
                kind: kind,
                name: agentName,
                state: agentState,
                message: agentMessage,
                priority: agentPriority
            )
            let info = HarborTerminalInfo(
                leaf: pane.terminal_id.map {
                    .herdrTerminal(host: host, sessionName: name, paneID: paneID, terminalID: $0)
                } ?? .herdrPane(host: host, sessionName: name, paneID: paneID),
                shortID: paneID,
                title: pane.terminal_title ?? "",
                isActive: pane.focused ?? false,
                cwd: pane.cwd,
                agent: agent,
                stableID: paneID
            )
            let workspaceID = pane.workspace_id ?? paneID.split(separator: ":").first.map(String.init) ?? ""
            panesByWorkspace[workspaceID, default: []].append(info)
        }
        var loose: [HarborTerminalInfo] = []
        let windows = workspaces.compactMap { workspace -> HarborWindowInfo? in
            let terminals = panesByWorkspace[workspace.workspace_id] ?? []
            guard !terminals.isEmpty else { return nil }
            let label = workspace.label ?? workspace.workspace_id
            let numbered = workspace.number.map { "\($0): \(label)" } ?? label
            return HarborWindowInfo(id: workspace.workspace_id, label: numbered, terminals: terminals)
        }
        let knownWorkspaceIDs = Set(workspaces.map(\.workspace_id))
        for (workspaceID, terminals) in panesByWorkspace where !knownWorkspaceIDs.contains(workspaceID) {
            loose.append(contentsOf: terminals)
        }
        return HarborSessionInfo(
            tool: .herdr, name: name, state: state, detail: detail,
            windows: windows, looseTerminals: loose
        )
    }

    private static func makeAgentInfo(
        kind: String?,
        name: String? = nil,
        state: String?,
        message: String?,
        priority: Int?
    ) -> HarborAgentInfo? {
        guard let kind, !kind.isEmpty else { return nil }
        let normalizedState = state?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let agentState = normalizedState.flatMap(HarborAgentState.init(rawValue:)) ?? .unknown
        return HarborAgentInfo(
            kind: kind,
            name: name,
            state: agentState,
            message: message,
            priority: priority
        )
    }
}

/// Lock-guarded buffers for the off-thread probe pipe drains.
private final class HarborProbeOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func storeStdout(_ data: Data) {
        lock.lock()
        stdout = data
        lock.unlock()
    }

    func storeStderr(_ data: Data) {
        lock.lock()
        stderr = data
        lock.unlock()
    }

    func takeStdout() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stdout
    }

    func takeStderr() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stderr
    }
}
