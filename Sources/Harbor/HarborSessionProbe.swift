import Foundation
import CmuxFoundation
import CmuxTmuxControlMode

/// The machine-readable Herdr session catalog. Keep this model separate from
/// the Harbor tree: the catalog is a discovery boundary, while pane/workspace
/// records are fetched through the session's JSON API below.
struct HarborHerdrSessionCatalogEntry: Decodable, Equatable, Sendable {
    let name: String
    let isDefault: Bool
    let running: Bool
    let sessionDirectory: String
    let socketPath: String

    enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "default"
        case running
        case sessionDirectory = "session_dir"
        case socketPath = "socket_path"
    }
}

private struct HarborHerdrSessionCatalog: Decodable {
    let sessions: [HarborHerdrSessionCatalogEntry]
}

/// Discovers the full session tree on one host by running one POSIX-sh
/// probe script: locally via `/bin/sh -s`, remotely via `ssh <dest> sh -s`.
/// Running Herdr sessions then receive bounded structured detail requests;
/// those requests stay outside the shell grammar so paths and names remain
/// lossless.
///
/// Line protocol (tab-separated; every stanza tolerates a missing tool):
///   `S <tool> <session> <state> <detail>`                       session
///   `TW <session> <window_id> <index> <name>`                   tmux window
///   `TP <session> <window_id> <pane_id> <active> <command>`     tmux pane
///   `J <tool> <session> <kind> <one-line-json>`                 cmux-tui / herdr
///   `C <tool> <capability> <0|1>`                                protocol capability
enum HarborSessionProbe {
    static let script = #"""
    #!/bin/sh
    emit() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

    # GUI launches do not promise the interactive shell's PATH. Resolve each
    # optional tool to an executable path before probing it, while retaining a
    # PATH fallback for custom installations and remote hosts.
    resolve_tool() {
      tool="$1"
      for candidate in \
        "${HOME:-}/.local/bin/$tool" \
        "/opt/homebrew/bin/$tool" \
        "/usr/local/bin/$tool" \
        "/opt/local/bin/$tool" \
        "/usr/bin/$tool" \
        "/bin/$tool"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
      done
      command -v "$tool" 2>/dev/null || true
    }

    TMUX_BIN=$(resolve_tool tmux)
    ZELLIJ_BIN=$(resolve_tool zellij)
    SCREEN_BIN=$(resolve_tool screen)
    ZMX_BIN=$(resolve_tool zmx)
    HERDR_BIN="${CMUX_HARBOR_HERDR_BINARY:-}"
    if [ -z "$HERDR_BIN" ] || [ ! -x "$HERDR_BIN" ]; then HERDR_BIN=$(resolve_tool herdr); fi

    if [ -n "$TMUX_BIN" ]; then
      "$TMUX_BIN" ls -F '#{session_name}	#{?session_attached,attached,detached}	#{session_windows}w' 2>/dev/null |
      while IFS='	' read -r n st d; do emit S tmux "$n" "$st" "$d"; done
      "$TMUX_BIN" list-windows -a -F 'TW	#{session_name}	#{window_id}	#{window_index}	#{window_name}' 2>/dev/null
      "$TMUX_BIN" list-panes -a -F 'TP	#{session_name}	#{window_id}	#{pane_id}	#{pane_active}	#{pane_current_command}' 2>/dev/null
    fi

    if [ -n "$ZELLIJ_BIN" ]; then
      if "$ZELLIJ_BIN" subscribe --help 2>&1 | grep -q -- '--format'; then
        printf 'C\tzellij\tsubscribe\t1\n'
      else
        printf 'C\tzellij\tsubscribe\t0\n'
      fi
      "$ZELLIJ_BIN" list-sessions --no-formatting 2>/dev/null |
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in *"(EXITED - attach to resurrect)"*) st=exited;; *) st=detached;; esac
        n="${line%% \[Created*}"
        if [ -n "$n" ]; then
          emit S zellij "$n" "$st" ""
          panes=$("$ZELLIJ_BIN" --session "$n" action list-panes --all --json 2>/dev/null | tr -d '\n')
          [ -n "$panes" ] && printf 'J\tzellij\t%s\tpane-list\t%s\n' "$n" "$panes"
        fi
      done
    fi

    if [ -n "$SCREEN_BIN" ]; then
      "$SCREEN_BIN" -ls 2>/dev/null | sed -n 's/^[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*(\(.*\))/\1	\2/p' |
      while IFS='	' read -r n st; do
        case "$st" in *ttached*) s=attached;; *) s=detached;; esac
        emit S screen "$n" "$s" ""
      done
    fi

    if [ -n "$ZMX_BIN" ]; then
      "$ZMX_BIN" list 2>/dev/null | while IFS= read -r line; do
        n=""; c=""
        for kv in $line; do
          case "$kv" in name=*) n=${kv#name=};; clients=*) c=${kv#clients=};; esac
        done
        [ -n "$n" ] || continue
        if [ "${c:-0}" -gt 0 ] 2>/dev/null; then s=attached; else s=detached; fi
        emit S zmx "$n" "$s" ""
      done
    fi

    if [ -n "$HERDR_BIN" ]; then
      # `--help` is the capability contract. Do not grep for record names:
      # Herdr's help text is intentionally short and may omit protocol details
      # while the command remains fully supported.
      if "$HERDR_BIN" terminal session control --help >/dev/null 2>&1; then
        printf 'C\therdr\tcontrol\t1\n'
      else
        printf 'C\therdr\tcontrol\t0\n'
      fi
      catalog=$("$HERDR_BIN" session list --json 2>/dev/null | tr -d '\n')
      if [ -n "$catalog" ]; then
        printf 'J\therdr\t__catalog__\tsession-list\t%s\n' "$catalog"
      else
        "$HERDR_BIN" session list 2>/dev/null | sed '1d' |
        while read -r n st _; do
          [ -n "$n" ] || continue
          emit S herdr "$n" "$st" ""
      done
      fi
    fi

    CT="${CMUX_HARBOR_TUI_BINARY:-}"
    if [ -n "$CT" ] && [ ! -x "$CT" ]; then CT=""; fi
    if [ -z "$CT" ]; then CT=$(resolve_tool cmux-tui); fi
    if [ -n "$CT" ]; then
      if "$CT" attach --help 2>&1 | grep -q -- '--pipe-io'; then
        printf 'C\tcmux-tui\tpipe-io\t1\n'
      else
        printf 'C\tcmux-tui\tpipe-io\t0\n'
      fi
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
            var localEnvironment: [String: String] = [
                "CMUX_HARBOR_TUI_BINARY": TuiTerminalAttachBridge.configuredBinaryPath
            ]
            if let herdr = HerdrControlModeGateway.resolveHerdrExecutable() {
                localEnvironment["CMUX_HARBOR_HERDR_BINARY"] = herdr
            }
            environment = localEnvironment
        } else {
            environment = nil
        }
        let output = try await runScript(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            environment: environment
        )
        let sessions = HarborProbeOutputParser.sessions(
            fromProbeOutput: output,
            host: host,
            ownSessionName: ownSessionName
        )
        return await enrichHerdrDetails(
            sessions,
            host: host,
            controlSupported: HarborProbeOutputParser.capability(
                "control",
                for: .herdr,
                fromProbeOutput: output
            ) == true,
            timeout: timeout
        )
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
        let result = await CommandRunner().run(
            directory: NSTemporaryDirectory(),
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            environmentOverrides: environment,
            standardInput: Data(script.utf8)
        )
        if result.timedOut {
            throw ProbeError.timedOut
        }
        if let executionError = result.executionError {
            _ = executionError
            throw ProbeError.launchFailed
        }
        guard result.exitStatus == 0 else {
            throw ProbeError.failed(
                exitCode: result.exitStatus ?? -1,
                stderr: result.stderr ?? ""
            )
        }
        return result.stdout ?? ""
    }

    /// Fetches Herdr's structured workspace, pane, and agent records after
    /// decoding the session catalog. The extra calls are intentional: Herdr
    /// exposes each resource through its own JSON API, and forcing those
    /// objects through the shell's whitespace grammar would corrupt paths or
    /// names. Four sessions are enriched at once to keep a large Harbor
    /// refresh bounded without serializing every SSH round trip.
    private static func enrichHerdrDetails(
        _ sessions: [HarborSessionInfo],
        host: HarborHostRef,
        controlSupported: Bool,
        timeout: TimeInterval
    ) async -> [HarborSessionInfo] {
        let running = sessions.filter { $0.tool == .herdr && $0.state == .running }
        guard !running.isEmpty else { return sessions }

        var detailsBySession: [String: [String: Data]] = [:]
        let batchSize = 4
        for start in stride(from: 0, to: running.count, by: batchSize) {
            let end = min(start + batchSize, running.count)
            let batch = running[start..<end]
            await withTaskGroup(of: (String, [String: Data]).self) { group in
                for session in batch {
                    group.addTask {
                        (
                            session.name,
                            await herdrDetails(
                                host: host,
                                sessionName: session.name,
                                timeout: min(timeout, 5)
                            )
                        )
                    }
                }
                for await (name, details) in group {
                    detailsBySession[name] = details
                }
            }
        }

        return sessions.map { session in
            guard session.tool == .herdr,
                  let details = detailsBySession[session.name],
                  !details.isEmpty else {
                return session
            }
            var synthetic = "C\therdr\tcontrol\t\(controlSupported ? 1 : 0)\n"
            synthetic += "S\therdr\t\(session.name)\t\(session.state.rawValue)\t\(session.detail)\n"
            for kind in ["workspace-list", "pane-list", "agent-list"] {
                guard let data = details[kind],
                      let json = String(data: data, encoding: .utf8) else {
                    continue
                }
                synthetic += "J\therdr\t\(session.name)\t\(kind)\t\(json)\n"
            }
            return HarborProbeOutputParser.sessions(
                fromProbeOutput: synthetic,
                host: host
            ).first ?? session
        }
    }

    private static let herdrDetailCommands: [(kind: String, arguments: [String])] = [
        ("workspace-list", ["workspace", "list"]),
        ("pane-list", ["pane", "list"]),
        ("agent-list", ["agent", "list"]),
    ]

    private static func herdrDetails(
        host: HarborHostRef,
        sessionName: String,
        timeout: TimeInterval
    ) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self, returning: [String: Data].self) { group in
            for command in herdrDetailCommands {
                group.addTask {
                    (
                        command.kind,
                        await runHerdrCommand(
                            host: host,
                            sessionName: sessionName,
                            arguments: command.arguments,
                            timeout: timeout
                        )
                    )
                }
            }
            var result: [String: Data] = [:]
            for await (kind, data) in group {
                if let data { result[kind] = data }
            }
            return result
        }
    }

    private static func runHerdrCommand(
        host: HarborHostRef,
        sessionName: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> Data? {
        let result: CommandResult
        switch host {
        case .local:
            let executable = HerdrControlModeGateway.resolveHerdrExecutable() ?? "herdr"
            result = await CommandRunner().run(
                directory: NSTemporaryDirectory(),
                executable: executable,
                arguments: ["--session", sessionName] + arguments,
                timeout: timeout
            )
        case .ssh(let destination):
            let remoteCommand = (["herdr", "--session", sessionName] + arguments)
                .map(shellQuote)
                .joined(separator: " ")
            result = await CommandRunner().run(
                directory: NSTemporaryDirectory(),
                executable: "/usr/bin/ssh",
                arguments: [
                    "-T",
                    "-o", "EscapeChar=none",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=6",
                    "--", destination, remoteCommand,
                ],
                timeout: timeout
            )
        }
        guard result.executionError == nil,
              !result.timedOut,
              result.exitStatus == 0,
              let stdout = result.stdout,
              let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return compact
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Assembles probe lines into per-session trees.
enum HarborProbeOutputParser {
    /// The JSON shape emitted by `zellij action list-panes --all --json`.
    /// Fields are optional because older Zellij versions omit fields unless a
    /// corresponding `--all` component is supported. `id` is the only field
    /// required to address a terminal action.
    private struct ZellijPaneRecord: Decodable, Sendable {
        let id: Int
        let isPlugin: Bool?
        let isFocused: Bool?
        let isSuppressed: Bool?
        let title: String?
        let exited: Bool?
        let tabID: Int?
        let tabPosition: Int?
        let tabName: String?
        let paneCommand: String?
        let terminalCommand: String?
        let paneCwd: String?
        let isSelectable: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case isPlugin = "is_plugin"
            case isFocused = "is_focused"
            case isSuppressed = "is_suppressed"
            case title
            case exited
            case tabID = "tab_id"
            case tabPosition = "tab_position"
            case tabName = "tab_name"
            case paneCommand = "pane_command"
            case terminalCommand = "terminal_command"
            case paneCwd = "pane_cwd"
            case isSelectable = "is_selectable"
        }
    }

    /// Reads one capability record without accepting a missing record as
    /// support. Discovery uses this to preserve the remote host's advertised
    /// Herdr control capability while enriching its JSON catalog.
    static func capability(
        _ capability: String,
        for tool: HarborTool,
        fromProbeOutput output: String
    ) -> Bool? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4,
                  fields[0] == "C",
                  fields[1] == tool.rawValue,
                  fields[2] == capability else {
                continue
            }
            return fields[3] == "1"
        }
        return nil
    }

    private static func capabilityValue(
        tool: HarborTool,
        name: String,
        capabilities: [String: Bool]
    ) -> Bool {
        capabilities["\(tool.rawValue)/\(name)"]
            ?? capabilities[tool.rawValue]
            ?? false
    }

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
        var capabilities: [String: Bool] = [:]
        var herdrCatalogEntries: [HarborHerdrSessionCatalogEntry] = []

        func sessionKey(_ tool: HarborTool, _ name: String) -> String { "\(tool.rawValue)/\(name)" }

        func addSession(
            tool: HarborTool,
            name: String,
            state: HarborSessionState,
            detail: String
        ) {
            guard !name.isEmpty else { return }
            if tool == .cmuxTui,
               HarborSessionInfo.isCmuxInfrastructureSession(name: name, ownSessionName: ownSessionName) {
                return
            }
            let key = sessionKey(tool, name)
            if sessions[key] == nil {
                sessionOrder.append(key)
            }
            sessions[key] = (tool, state, detail)
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "S":
                guard fields.count >= 4, let tool = HarborTool(rawValue: fields[1]) else { continue }
                addSession(
                    tool: tool,
                    name: fields[2],
                    state: HarborSessionState(rawValue: fields[3]) ?? .unknown,
                    detail: fields.count > 4 ? fields[4] : ""
                )
            case "TW":
                guard fields.count >= 5,
                      let windowID = tmuxID(fields[2], prefix: "@"),
                      let index = Int(fields[3]) else { continue }
                tmuxWindows[fields[1], default: []].append((windowID, index, fields[4]))
            case "TP":
                guard fields.count >= 4,
                      let windowID = tmuxID(fields[2], prefix: "@"),
                      let paneID = tmuxID(fields[3], prefix: "%") else { continue }
                // The line parser deliberately stops after four separators so
                // a session detail can contain tabs. For a TP record, split
                // the retained tail once more into the active bit and the
                // command. The old code dropped the command by trying to skip
                // a tab that had already been retained in `fields[4]`.
                let tail = fields.count > 4 ? fields[4] : ""
                let paneFields = tail.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                let active = paneFields.first == "1"
                let command = paneFields.count > 1 ? String(paneFields[1]) : ""
                tmuxPanes[fields[1], default: [:]][windowID, default: []]
                    .append((paneID, active, command))
            case "J":
                guard fields.count >= 5, let tool = HarborTool(rawValue: fields[1]) else { continue }
                if tool == .herdr,
                   fields[2] == "__catalog__",
                   fields[3] == "session-list",
                   let data = fields[4].data(using: .utf8),
                   let catalog = try? JSONDecoder().decode(HarborHerdrSessionCatalog.self, from: data) {
                    herdrCatalogEntries = catalog.sessions
                    continue
                }
                jsonLines[sessionKey(tool, fields[2]), default: [:]][fields[3]] = Data(fields[4].utf8)
            case "C":
                guard fields.count >= 4, HarborTool(rawValue: fields[1]) != nil else { continue }
                // Keep both the named capability and the legacy tool-only
                // value. The latter preserves old fixtures; new adapters must
                // request a specific capability so one tool cannot
                // accidentally inherit another protocol's result.
                capabilities["\(fields[1])/\(fields[2])"] = fields[3] == "1"
                capabilities[fields[1]] = capabilities[fields[1]] ?? (fields[3] == "1")
            default:
                // Keep accepting the four-column protocol emitted by the
                // first Harbor build. This is useful for persisted probe
                // fixtures and makes the parser tolerant of an older helper
                // script on a remote host.
                guard fields.count >= 3,
                      let rawTool = fields.first,
                      let tool = HarborTool(rawValue: rawTool) else { continue }
                addSession(
                    tool: tool,
                    name: fields[1],
                    state: HarborSessionState(rawValue: fields[2]) ?? .unknown,
                    detail: fields.count > 3 ? fields[3] : ""
                )
            }
        }

        // A JSON catalog is authoritative for Herdr identity. Add it after
        // the line scan so an older helper's S record can be upgraded with
        // the canonical socket path without duplicating the row.
        for entry in herdrCatalogEntries {
            addSession(
                tool: .herdr,
                name: entry.name,
                state: entry.running ? .running : .stopped,
                detail: entry.socketPath
            )
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
                    json: jsonLines[key] ?? [:],
                    // A direct renderer-less attach is enabled only when the
                    // probe positively verified the exact client capability.
                    // Missing capability metadata means an older or truncated
                    // probe, not proof that the protocol exists.
                    directAttachSupported: capabilityValue(
                        tool: .cmuxTui, name: "pipe-io", capabilities: capabilities
                    )
                )
            case .herdr:
                return herdrSessionInfo(
                    host: host, name: name, state: base.state, detail: base.detail,
                    json: jsonLines[key] ?? [:],
                    directAttachSupported: capabilityValue(
                        tool: .herdr, name: "control", capabilities: capabilities
                    )
                )
            case .zellij:
                return zellijSessionInfo(
                    host: host,
                    name: name,
                    state: base.state,
                    detail: base.detail,
                    json: jsonLines[key] ?? [:],
                    directAttachSupported: capabilityValue(
                        tool: .zellij, name: "subscribe", capabilities: capabilities
                    )
                )
            case .screen, .zmx:
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

    private static func zellijSessionInfo(
        host: HarborHostRef,
        name: String,
        state: HarborSessionState,
        detail: String,
        json: [String: Data],
        directAttachSupported: Bool
    ) -> HarborSessionInfo {
        let decoder = JSONDecoder()
        let records = (json["pane-list"].flatMap {
            try? decoder.decode([ZellijPaneRecord].self, from: $0)
        }) ?? []

        var tabs: [Int: [HarborTerminalInfo]] = [:]
        var tabLabels: [Int: (position: Int, name: String)] = [:]
        var loose: [HarborTerminalInfo] = []
        for record in records {
            // Harbor lists terminal panes only. Zellij's tab/status plugins
            // are not user terminals and cannot accept terminal input.
            guard record.isPlugin != true,
                  record.isSelectable != false,
                  record.isSuppressed != true,
                  record.exited != true else { continue }
            let paneID = "terminal_\(record.id)"
            let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? record.paneCommand
                ?? record.terminalCommand
                ?? paneID
            let info = HarborTerminalInfo(
                leaf: directAttachSupported ? .zellijPane(
                    host: host, sessionName: name, paneID: paneID
                ) : nil,
                shortID: paneID,
                title: title,
                isActive: record.isFocused == true,
                cwd: record.paneCwd,
                stableID: paneID
            )
            guard let tabID = record.tabID else {
                loose.append(info)
                continue
            }
            tabs[tabID, default: []].append(info)
            tabLabels[tabID] = (
                position: record.tabPosition ?? tabID,
                name: record.tabName?.isEmpty == false ? record.tabName! : "Tab #\(record.tabPosition ?? tabID + 1)"
            )
        }

        let windows = tabs.keys.sorted { lhs, rhs in
            let left = tabLabels[lhs]?.position ?? lhs
            let right = tabLabels[rhs]?.position ?? rhs
            return left == right ? lhs < rhs : left < right
        }.compactMap { tabID -> HarborWindowInfo? in
            guard let terminals = tabs[tabID], !terminals.isEmpty else { return nil }
            let labelInfo = tabLabels[tabID]
            let position = labelInfo?.position ?? tabID
            let label = labelInfo?.name ?? "Tab #\(position + 1)"
            return HarborWindowInfo(
                id: "tab_\(tabID)",
                label: "\(position + 1): \(label)",
                terminals: terminals
            )
        }
        return HarborSessionInfo(
            tool: .zellij,
            name: name,
            state: state,
            detail: detail,
            windows: windows,
            looseTerminals: loose
        )
    }

    private static func tuiSessionInfo(
        host: HarborHostRef,
        name: String,
        state: HarborSessionState,
        socketPath: String,
        json: [String: Data],
        directAttachSupported: Bool = false
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
                leaf: directAttachSupported ? .tuiTerminal(
                    host: host, sessionName: name,
                    socketPath: localSocketPath, terminalID: terminal.id
                ) : nil,
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
        json: [String: Data],
        directAttachSupported: Bool = false
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
                leaf: directAttachSupported ? pane.terminal_id.map {
                    .herdrTerminal(host: host, sessionName: name, paneID: paneID, terminalID: $0)
                } ?? .herdrPane(host: host, sessionName: name, paneID: paneID) : nil,
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
