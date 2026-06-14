import Foundation

extension CMUXCLI {
    private struct ListSurfacesCommandOptions {
        let includeAllWindows: Bool
        let workspaceHandle: String?
        let windowHandle: String?
        let jsonOutput: Bool
        let terminalOnly: Bool
    }

    func runListSurfacesCommand(
        commandName: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        terminalOnly: Bool
    ) throws {
        let options = try parseListSurfacesCommandOptions(
            commandArgs,
            commandName: commandName,
            terminalOnly: terminalOnly
        )
        let payload = try buildListSurfacesPayload(
            options: options,
            client: client
        )
        if jsonOutput || options.jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaces = payload["surfaces"] as? [[String: Any]] ?? []
            print(renderListSurfacesText(
                surfaces: surfaces,
                idFormat: idFormat,
                terminalOnly: terminalOnly
            ))
        }
    }

    private func parseListSurfacesCommandOptions(
        _ args: [String],
        commandName: String,
        terminalOnly: Bool
    ) throws -> ListSurfacesCommandOptions {
        let workspaceWasProvided = listSurfaceOptionWasProvided(args, name: "--workspace")
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if listSurfaceOptionRequiresHandle(workspaceOpt, wasProvided: workspaceWasProvided) {
            throw CLIError(message: String(format: String(
                localized: "cli.listSurfaces.error.missingHandleOption",
                defaultValue: "%@ requires %@ <id|ref|index>"
            ), commandName, "--workspace"))
        }
        let windowWasProvided = listSurfaceOptionWasProvided(rem0, name: "--window")
        let (windowOpt, rem1) = parseOption(rem0, name: "--window")
        if listSurfaceOptionRequiresHandle(windowOpt, wasProvided: windowWasProvided) {
            throw CLIError(message: String(format: String(
                localized: "cli.listSurfaces.error.missingHandleOption",
                defaultValue: "%@ requires %@ <id|ref|index>"
            ), commandName, "--window"))
        }

        var includeAll = false
        var jsonOutput = false
        var remaining: [String] = []
        for arg in rem1 {
            if arg == "--all" {
                includeAll = true
                continue
            }
            if arg == "--json" {
                jsonOutput = true
                continue
            }
            remaining.append(arg)
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: String(format: String(
                localized: "cli.listSurfaces.error.unknownFlag",
                defaultValue: "%@: unknown flag '%@'. Known flags: --all --workspace <id|ref|index> --window <id|ref|index> --json"
            ), commandName, unknown))
        }
        if let extra = remaining.first {
            throw CLIError(message: String(format: String(
                localized: "cli.listSurfaces.error.unexpectedArgument",
                defaultValue: "%@: unexpected argument '%@'"
            ), commandName, extra))
        }
        if includeAll, let scopedOption = windowOpt != nil ? "--window" : (workspaceOpt != nil ? "--workspace" : nil) {
            throw CLIError(message: String(format: String(
                localized: "cli.listSurfaces.error.windowWithAll",
                defaultValue: "%@: %@ cannot be combined with --all"
            ), commandName, scopedOption))
        }

        let includeAllByDefault = windowOpt == nil && workspaceOpt == nil
        return ListSurfacesCommandOptions(
            includeAllWindows: includeAll || includeAllByDefault,
            workspaceHandle: workspaceOpt,
            windowHandle: windowOpt,
            jsonOutput: jsonOutput,
            terminalOnly: terminalOnly
        )
    }

    private func listSurfaceOptionWasProvided(_ args: [String], name: String) -> Bool {
        var pastTerminator = false
        for arg in args {
            if arg == "--" {
                pastTerminator = true
                continue
            }
            if !pastTerminator, arg == name || arg.hasPrefix("\(name)=") {
                return true
            }
        }
        return false
    }

    private func listSurfaceOptionRequiresHandle(_ value: String?, wasProvided: Bool) -> Bool {
        guard wasProvided else { return false }
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("-")
    }

    private func buildListSurfacesPayload(
        options: ListSurfacesCommandOptions,
        client: SocketClient
    ) throws -> [String: Any] {
        let treePayload = try buildTreePayload(
            options: TreeCommandOptions(
                includeAllWindows: options.includeAllWindows,
                workspaceHandle: options.workspaceHandle,
                windowHandle: options.windowHandle,
                jsonOutput: options.jsonOutput
            ),
            client: client
        )
        let surfaces = flattenTreeSurfaces(
            payload: treePayload,
            terminalOnly: options.terminalOnly
        )
        return [
            "count": surfaces.count,
            "terminal_only": options.terminalOnly,
            "surfaces": surfaces
        ]
    }

    private func flattenTreeSurfaces(
        payload: [String: Any],
        terminalOnly: Bool
    ) -> [[String: Any]] {
        let windows = payload["windows"] as? [[String: Any]] ?? []
        let activeSurfaceHandle = listSurfaceActiveHandle(payload)
        var result: [[String: Any]] = []

        for window in windows {
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for pane in panes {
                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for surface in surfaces {
                        let type = ((surface["type"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        if terminalOnly, type != "terminal" {
                            continue
                        }

                        var row = surface
                        copyTreeListContext(into: &row, kind: "surface", from: surface)
                        copyTreeListContext(into: &row, kind: "pane", from: pane)
                        copyTreeListContext(into: &row, kind: "workspace", from: workspace)
                        copyTreeListContext(into: &row, kind: "window", from: window)
                        copyTreeListValue(into: &row, key: "surface_index", from: surface["index"] ?? surface["index_in_pane"])
                        copyTreeListValue(into: &row, key: "pane_index", from: pane["index"])
                        copyTreeListValue(into: &row, key: "workspace_index", from: workspace["index"])
                        copyTreeListValue(into: &row, key: "workspace_title", from: workspace["title"])
                        copyTreeListValue(into: &row, key: "window_index", from: window["index"])
                        copyTreeListValue(into: &row, key: "window_key", from: window["key"])
                        copyTreeListValue(into: &row, key: "pane_focused", from: pane["focused"])
                        row["active"] = listSurfaceMatchesHandle(surface, handle: activeSurfaceHandle)
                            || listSurfaceBool(surface["active"])
                        result.append(row)
                    }
                }
            }
        }

        return result
    }

    private func listSurfaceActiveHandle(_ payload: [String: Any]) -> String? {
        guard let active = payload["active"] as? [String: Any] else { return nil }
        return listSurfaceHandle(active, refKey: "surface_ref", idKey: "surface_id")
    }

    private func listSurfaceMatchesHandle(_ surface: [String: Any], handle: String?) -> Bool {
        guard let handle else { return false }
        return ["ref", "id", "surface_ref", "surface_id"].contains { key in
            listSurfaceHandleString(surface[key]) == handle
        }
    }

    private func listSurfaceHandle(
        _ item: [String: Any],
        refKey: String,
        idKey: String
    ) -> String? {
        if let ref = listSurfaceHandleString(item[refKey]) {
            return ref
        }
        return listSurfaceHandleString(item[idKey])
    }

    private func listSurfaceHandleString(_ value: Any?) -> String? {
        guard let string = listSurfaceDebugString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }

    private func listSurfaceBool(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes":
                return true
            default:
                return false
            }
        }
        return false
    }

    private func copyTreeListContext(
        into row: inout [String: Any],
        kind: String,
        from source: [String: Any]
    ) {
        copyTreeListValue(into: &row, key: "\(kind)_id", from: source["id"])
        copyTreeListValue(into: &row, key: "\(kind)_ref", from: source["ref"])
    }

    private func copyTreeListValue(
        into row: inout [String: Any],
        key: String,
        from value: Any?
    ) {
        guard row[key] == nil, let value else { return }
        row[key] = value
    }

    private func renderListSurfacesText(
        surfaces: [[String: Any]],
        idFormat: CLIIDFormat,
        terminalOnly: Bool
    ) -> String {
        guard !surfaces.isEmpty else {
            return terminalOnly
                ? String(localized: "cli.listTerminals.empty", defaultValue: "No terminal surfaces")
                : String(localized: "cli.listSurfaces.empty", defaultValue: "No surfaces")
        }

        return surfaces.map { row in
            var parts: [String] = []
            let prefix = (row["active"] as? Bool) == true ? "* " : "  "
            let surface = formatHandle(row, kind: "surface", idFormat: idFormat)
                ?? listSurfaceFallbackHandle(row, idFormat: idFormat)
            let rawType = ((row["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let type = rawType.isEmpty ? "unknown" : rawType
            parts.append("\(prefix)\(surface)")
            parts.append(type)
            parts.append("window=\(formatHandle(row, kind: "window", idFormat: idFormat) ?? "?")")
            parts.append("workspace=\(formatHandle(row, kind: "workspace", idFormat: idFormat) ?? "?")")
            parts.append("pane=\(formatHandle(row, kind: "pane", idFormat: idFormat) ?? "?")")
            if let title = listSurfaceDebugString(row["title"]), !title.isEmpty {
                parts.append("\"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"")
            }
            if let tty = listSurfaceDebugString(row["tty"]), !tty.isEmpty {
                parts.append("tty=\(tty)")
            }
            if type.lowercased() == "browser",
               let url = listSurfaceDebugString(row["url"]),
               !url.isEmpty {
                parts.append(url)
            }
            return parts.joined(separator: "  ")
        }
        .joined(separator: "\n")
    }

    private func listSurfaceFallbackHandle(
        _ item: [String: Any],
        idFormat: CLIIDFormat
    ) -> String {
        let ref = item["ref"] as? String
        let id = item["id"] as? String
        switch idFormat {
        case .refs:
            return ref ?? id ?? "?"
        case .uuids:
            return id ?? ref ?? "?"
        case .both:
            if let ref, let id {
                return "\(ref) \(id)"
            }
            return ref ?? id ?? "?"
        }
    }

    private func listSurfaceDebugString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return String(describing: value)
    }
}
