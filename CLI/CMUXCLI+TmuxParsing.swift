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


// MARK: - tmux compat argument parsing
extension CMUXCLI {
    struct TmuxParsedArguments {
        var flags: Set<String> = []
        var options: [String: [String]] = [:]
        var positional: [String] = []

        func hasFlag(_ flag: String) -> Bool {
            flags.contains(flag)
        }

        func value(_ flag: String) -> String? {
            options[flag]?.last
        }
    }

    func parseTmuxArguments(
        _ args: [String],
        valueFlags: Set<String>,
        boolFlags: Set<String>
    ) throws -> TmuxParsedArguments {
        var parsed = TmuxParsedArguments()
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let arg = args[index]
            if pastTerminator {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            if !arg.hasPrefix("-") || arg == "-" {
                parsed.positional.append(arg)
                index += 1
                continue
            }
            if arg.hasPrefix("--") {
                parsed.positional.append(arg)
                index += 1
                continue
            }

            let cluster = Array(arg.dropFirst())
            var cursor = 0
            var recognizedArgument = false
            while cursor < cluster.count {
                let flag = "-" + String(cluster[cursor])
                if boolFlags.contains(flag) {
                    parsed.flags.insert(flag)
                    cursor += 1
                    recognizedArgument = true
                    continue
                }
                if valueFlags.contains(flag) {
                    let remainder = String(cluster.dropFirst(cursor + 1))
                    let value: String
                    if !remainder.isEmpty {
                        value = remainder
                    } else {
                        guard index + 1 < args.count else {
                            throw CLIError(message: "\(flag) requires a value")
                        }
                        index += 1
                        value = args[index]
                    }
                    parsed.options[flag, default: []].append(value)
                    recognizedArgument = true
                    cursor = cluster.count
                    continue
                }

                recognizedArgument = false
                break
            }

            if !recognizedArgument {
                parsed.positional.append(arg)
            }
            index += 1
        }

        return parsed
    }

    func splitTmuxCommand(_ args: [String]) throws -> (command: String, args: [String]) {
        var index = 0
        let globalValueFlags: Set<String> = ["-L", "-S", "-f"]
        let globalBoolFlags: Set<String> = ["-V", "-v"]

        while index < args.count {
            let arg = args[index]
            if !arg.hasPrefix("-") || arg == "-" {
                return (arg.lowercased(), Array(args.dropFirst(index + 1)))
            }
            if arg == "--" {
                break
            }
            // Handle -V (version) as a pseudo-command
            if globalBoolFlags.contains(arg) {
                return (arg, [])
            }
            if let flag = globalValueFlags.first(where: { arg == $0 || arg.hasPrefix($0) }) {
                if arg == flag {
                    index += 1
                }
            }
            index += 1
        }

        throw CLIError(message: "tmux shim requires a command")
    }

    func normalizedTmuxTarget(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func tmuxStableNumericId(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = trimmed.isEmpty ? "cmux" : trimmed
        var hash: UInt64 = 14695981039346656037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let value = hash & 0x7fffffffffffffff
        return String(value == 0 ? 1 : value)
    }

    private func tmuxTrimIdSigil(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = trimmed.first, first == "$" || first == "@" || first == "%" {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    func tmuxSelectorToken(_ raw: String) -> (token: String, sigiled: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tmuxTrimIdSigil(trimmed)
        return (token, token != trimmed)
    }

    private func tmuxNumericIdMatches(_ handle: String, candidates: [String?]) -> Bool {
        let token = tmuxTrimIdSigil(handle)
        guard !token.isEmpty else { return false }
        return candidates.contains { candidate in
            guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty else { return false }
            return token == tmuxStableNumericId(candidate)
        }
    }

    private func tmuxIndexMatches(_ handle: String, index: Int?) -> Bool {
        guard let index else { return false }
        return tmuxTrimIdSigil(handle) == String(index)
    }

    private func tmuxNormalizePath(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = URL(
                fileURLWithPath: path,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            ).path
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func tmuxPathFromObject(_ object: [String: Any]) -> String? {
        for key in [
            "pane_current_path",
            "current_directory",
            "requested_working_directory",
            "working_directory",
            "cwd"
        ] {
            if let path = tmuxNormalizePath(object[key] as? String) {
                return path
            }
        }
        if let binding = object["resume_binding"] as? [String: Any],
           let path = tmuxNormalizePath(binding["cwd"] as? String) {
            return path
        }
        return nil
    }

    func tmuxFallbackCurrentPath() -> String {
        tmuxNormalizePath(ProcessInfo.processInfo.environment["PWD"])
            ?? tmuxNormalizePath(FileManager.default.currentDirectoryPath)
            ?? tmuxNormalizePath(NSHomeDirectory())
            ?? "/"
    }

    func tmuxWindowSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") || trimmed.hasPrefix("pane:") {
            return nil
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[..<dot])
        }
        return trimmed
    }

    func tmuxPaneSelector(from raw: String?) -> String? {
        guard let trimmed = normalizedTmuxTarget(raw) else { return nil }
        if trimmed.hasPrefix("%") {
            return trimmed
        }
        if trimmed.hasPrefix("pane:") {
            return trimmed
        }
        if let dot = trimmed.lastIndex(of: ".") {
            return String(trimmed[trimmed.index(after: dot)...])
        }
        return nil
    }

    func tmuxWorkspaceItems(client: SocketClient) throws -> [[String: Any]] {
        let payload = try client.sendV2(method: "workspace.list")
        return payload["workspaces"] as? [[String: Any]] ?? []
    }

    func tmuxCallerWorkspaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"])
    }

    func tmuxCallerPaneHandle() -> String? {
        guard let pane = normalizedTmuxTarget(ProcessInfo.processInfo.environment["TMUX_PANE"])
            ?? normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_PANE_ID"]) else {
            return nil
        }
        return pane.hasPrefix("%") ? String(pane.dropFirst()) : pane
    }

    func tmuxCallerSurfaceHandle() -> String? {
        normalizedTmuxTarget(ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"])
    }

    func tmuxResolvedCallerWorkspaceId(client: SocketClient) -> String? {
        guard let callerWorkspace = tmuxCallerWorkspaceHandle() else {
            return nil
        }
        return try? resolveWorkspaceId(callerWorkspace, client: client)
    }

    func tmuxCanonicalPaneId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        let selector = tmuxSelectorToken(handle)
        let normalizedHandle = selector.token
        if isUUID(normalizedHandle) {
            return normalizedHandle
        }

        let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = payload["panes"] as? [[String: Any]] ?? []
        for pane in panes {
            let id = pane["id"] as? String
            let ref = pane["ref"] as? String
            if id == normalizedHandle || (!selector.sigiled && ref == normalizedHandle) {
                if let id = pane["id"] as? String {
                    return id
                }
            }
            if tmuxNumericIdMatches(normalizedHandle, candidates: [id, ref]),
               let id {
                return id
            }
        }

        if !selector.sigiled, let index = Int(normalizedHandle) {
            for pane in panes where intFromAny(pane["index"]) == index {
                if let id = pane["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Pane target not found")
    }

    func tmuxCanonicalSurfaceId(
        _ handle: String,
        workspaceId: String,
        client: SocketClient
    ) throws -> String {
        let selector = tmuxSelectorToken(handle)
        let normalizedHandle = selector.token
        let payload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])
        let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces {
            let id = surface["id"] as? String
            let ref = surface["ref"] as? String
            if id == normalizedHandle || (!selector.sigiled && ref == normalizedHandle) {
                if let id = surface["id"] as? String {
                    return id
                }
            }
            if tmuxNumericIdMatches(normalizedHandle, candidates: [id, ref]),
               let id {
                return id
            }
        }

        if !selector.sigiled, let index = Int(normalizedHandle) {
            for surface in surfaces where intFromAny(surface["index"]) == index {
                if let id = surface["id"] as? String {
                    return id
                }
            }
        }

        throw CLIError(message: "Surface target not found")
    }

    func tmuxWorkspaceIdForPaneHandle(_ handle: String, client: SocketClient) throws -> String? {
        let selector = tmuxSelectorToken(handle)
        let normalizedHandle = selector.token

        let workspaces = try tmuxWorkspaceItems(client: client)
        for workspace in workspaces {
            guard let workspaceId = workspace["id"] as? String else { continue }
            let payload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
            let panes = payload["panes"] as? [[String: Any]] ?? []
            if panes.contains(where: { pane in
                let id = pane["id"] as? String
                let ref = pane["ref"] as? String
                return id == normalizedHandle
                    || (!selector.sigiled && ref == normalizedHandle)
                    || tmuxNumericIdMatches(normalizedHandle, candidates: [id, ref])
                    || (!selector.sigiled && tmuxIndexMatches(normalizedHandle, index: intFromAny(pane["index"])))
            }) {
                return workspaceId
            }
        }

        return nil
    }

    func tmuxWorkspaceIdForCompatHandle(_ handle: String, client: SocketClient) throws -> String? {
        let selector = tmuxSelectorToken(handle)
        let normalizedHandle = selector.token
        let items = try tmuxWorkspaceItems(client: client)
        for item in items {
            let id = item["id"] as? String
            let ref = item["ref"] as? String
            if id == normalizedHandle || (!selector.sigiled && ref == normalizedHandle) {
                return id
            }
            if tmuxNumericIdMatches(normalizedHandle, candidates: [id, ref]) {
                return id
            }
            if !selector.sigiled, tmuxIndexMatches(normalizedHandle, index: intFromAny(item["index"])) {
                return id
            }
        }
        return nil
    }

    func tmuxFocusedPaneId(workspaceId: String, client: SocketClient) throws -> String {
        let payload = try client.sendV2(method: "surface.current", params: ["workspace_id": workspaceId])
        if let paneId = payload["pane_id"] as? String {
            return paneId
        }
        if let paneRef = payload["pane_ref"] as? String {
            return try tmuxCanonicalPaneId(paneRef, workspaceId: workspaceId, client: client)
        }
        throw CLIError(message: "Pane target not found")
    }

}
