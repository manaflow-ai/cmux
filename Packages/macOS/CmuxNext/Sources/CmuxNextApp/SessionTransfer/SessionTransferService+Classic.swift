import CmuxNextControl
import CmuxNextSessionTransfer
import CmuxNextSettings
import Foundation

/// Classic cmux peers: their sessions read from `window.list`, `workspace.list` and `surface.list`.
extension SessionTransferService {
    /// Classic's `workspace.list` covers one window, so walk `window.list`.
    static func discoverClassicItems(path: String) async -> [SessionTransferItem] {
        let windows = (try? await ControlPeerClient.request(path: path, method: "window.list"))?["windows"]?.arrayValue ?? []
        let windowIDs: [String?] = windows.isEmpty ? [nil] : windows.compactMap { $0["id"]?.stringValue }
        var items: [SessionTransferItem] = []
        for windowID in windowIDs {
            let windowParams: [String: TransferJSONValue] = windowID.map { ["window_id": .string($0)] } ?? [:]
            guard let result = try? await ControlPeerClient.request(path: path, method: "workspace.list", params: windowParams),
                  let workspaces = result["workspaces"]?.arrayValue else { continue }
            for workspace in workspaces {
                guard let object = workspace.objectValue,
                      let workspaceID = object["id"]?.stringValue ?? object["ref"]?.stringValue else { continue }
                let fallbackCWD = object["current_directory"]?.stringValue
                var params = windowParams
                params["workspace_id"] = .string(workspaceID)
                guard let result = try? await ControlPeerClient.request(path: path, method: "surface.list", params: params),
                      let surfaces = result["surfaces"]?.arrayValue else { continue }
                for surface in surfaces {
                    guard let item = Self.classicItem(surface, workspace: workspaceID, fallbackCWD: fallbackCWD) else { continue }
                    items.append(item)
                }
            }
        }
        return items
    }

    private static func classicItem(_ value: TransferJSONValue, workspace: String, fallbackCWD: String?) -> SessionTransferItem? {
        guard let object = value.objectValue,
              let sourceSurface = object["id"]?.stringValue ?? object["ref"]?.stringValue else { return nil }
        let type = object["type"]?.stringValue ?? ""
        guard type == "terminal" || type == "pty" else { return nil }
        let binding = object["resume_binding"]?.objectValue
        // Classic keeps the agent's session id inside its resume command
        // (`claude --resume <id>`, `codex resume <id>`).
        let harness = binding?["kind"]?.stringValue.flatMap { ["claude", "codex"].contains($0) ? $0 : nil }
        let session = harness.flatMap { harness in
            [binding?["command"]?.stringValue, binding?["launch_command"]?.stringValue]
                .lazy.compactMap { Self.agentSessionID(harness: harness, command: $0) }.first
        }
        let isAgent = harness != nil && session != nil
        let command = object["initial_command"]?.stringValue ?? binding?["command"]?.stringValue
        // Only an SSH command is replayed; a classic terminal's other launch
        // command may be one-shot (a deploy), so it reopens as a shell.
        let cwd = object["requested_working_directory"]?.stringValue ?? binding?["cwd"]?.stringValue ?? fallbackCWD
        let sshTarget = object["ssh_target"]?.stringValue ?? Self.sshTarget(from: command)
        let title = object["title"]?.stringValue ?? ""
        return SessionTransferItem(sourceSurface: sourceSurface, workspace: workspace,
                                   kind: isAgent ? SessionTransferItem.Kind.agent : SessionTransferItem.Kind.terminal, title: title, cwd: cwd,
                                   sshTarget: sshTarget, command: nil,
                                   agentHarness: isAgent ? harness : nil,
                                   agentSessionID: isAgent ? session : nil)
    }

    /// The session id in a classic resume command: `claude --resume|-r|--session-id <id>`
    /// or `codex resume <id>`.
    static func agentSessionID(harness: String, command: String?) -> String? {
        guard let command else { return nil }
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        let flags: Set<String> = harness == "codex" ? ["resume"] : ["--resume", "-r", "--session-id"]
        guard let index = tokens.firstIndex(where: flags.contains), index + 1 < tokens.count else { return nil }
        let id = tokens[index + 1]
        return id.isEmpty || id.hasPrefix("-") ? nil : id
    }

    private static func sshTarget(from command: String?) -> String? {
        guard let command else { return nil }
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let index = tokens.firstIndex(where: { $0 == "ssh" || $0.hasSuffix("/ssh") }) else { return nil }
        var skipNext = false
        for token in tokens.dropFirst(index + 1) {
            if skipNext { skipNext = false; continue }
            if token == "--" { continue }
            if token == "-p" || token == "-o" || token == "-J" { skipNext = true; continue }
            if token.hasPrefix("-") { continue }
            return token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return nil
    }
}
