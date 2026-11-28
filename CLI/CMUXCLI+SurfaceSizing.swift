import Foundation

/// `cmux surface size…` verbs for shared terminal sizing
/// (docs/shared-terminal-sizing.md). Each maps to one v2 socket method that
/// the app routes through `TerminalSharingStore`, the same path as the tab
/// menu, size panel, shortcut and command palette.
extension CMUXCLI {
    func runSurfaceSizingCommand(
        subcommand: String,
        rest: [String],
        client: SocketClient,
        jsonOutput: Bool,
        windowOverride: String?
    ) throws {
        let target = try surfaceResumeTarget(rest, client: client, windowOverride: windowOverride)
        var params = target.params
        var remaining = target.remaining
        let method: String
        switch subcommand {
        case "size":
            method = "terminal.size_state"
        case "participants":
            method = "terminal.size_state"
        case "size-to-me":
            method = "terminal.size_to_me"
        case "disconnect-others":
            method = "terminal.participants.disconnect_others"
        case "size-policy":
            let (cols, afterCols) = parseOption(remaining, name: "--cols")
            let (rows, afterRows) = parseOption(afterCols, name: "--rows")
            remaining = afterRows
            guard let mode = remaining.first else {
                throw CLIError(message: "surface size-policy requires a mode: latest, smallest, largest, priority or fixed")
            }
            remaining.removeFirst()
            params["mode"] = mode.lowercased()
            if let cols, let rows {
                guard let colsValue = Int(cols), let rowsValue = Int(rows) else {
                    throw CLIError(message: "surface size-policy: --cols and --rows must be integers")
                }
                params["fixed_cols"] = colsValue
                params["fixed_rows"] = rowsValue
            }
            method = "terminal.size_policy.set"
        case "size-counts":
            let (participant, afterParticipant) = parseOption(remaining, name: "--participant")
            remaining = afterParticipant
            guard let value = remaining.first?.lowercased() else {
                throw CLIError(message: "surface size-counts requires true, false or auto")
            }
            remaining.removeFirst()
            switch value {
            case "true", "on", "yes": params["counts"] = true
            case "false", "off", "no", "viewer": params["counts"] = false
            case "auto", "null", "clear": params["counts"] = NSNull()
            default: throw CLIError(message: "surface size-counts: expected true, false or auto, got '\(value)'")
            }
            if let participant { params["participant_id"] = participant }
            method = "terminal.size_counts.set"
        case "disconnect-participant":
            guard let participant = remaining.first else {
                throw CLIError(message: "surface disconnect-participant requires a participant id (see `cmux surface participants`)")
            }
            remaining.removeFirst()
            params["participant_id"] = participant
            method = "terminal.participant.disconnect"
        default:
            throw CLIError(message: "Unsupported surface subcommand: \(subcommand)")
        }
        if let unexpected = remaining.first {
            throw CLIError(message: "surface \(subcommand): unexpected argument '\(unexpected)'")
        }
        let payload = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        print(Self.sizingSummary(payload, listParticipants: subcommand == "participants" || subcommand == "size"))
    }

    /// Plain-text summary: the grid and why, then one line per participant.
    static func sizingSummary(_ payload: [String: Any], listParticipants: Bool) -> String {
        guard let state = payload["size_state"] as? [String: Any],
              let cols = state["cols"] as? Int, let rows = state["rows"] as? Int else {
            return "Terminal is not shared"
        }
        let selfID = payload["self_participant_id"] as? String
        let owners = Set(state["owners"] as? [String] ?? [])
        let mode = (state["policy"] as? [String: Any])?["mode"] as? String ?? "smallest"
        var lines = ["\(cols)x\(rows)  mode=\(mode)  reason=\(state["reason"] as? String ?? "")"]
        if let detachment = payload["detachment"] as? [String: Any] {
            // The grid above is the last state seen before this view was detached.
            var detached = "detached  reason=\(detachment["reason"] as? String ?? "unknown")"
            if let by = detachment["by"] as? [String: Any],
               let name = (by["display_name"] as? String) ?? (by["device_name"] as? String) {
                detached += "  by=\(name)"
                if let device = by["device_name"] as? String, device != name { detached += " (\(device))" }
            }
            if let at = detachment["at"] as? String { detached += "  at=\(at)" }
            lines.append(detached)
        }
        if let disconnected = payload["disconnected"] as? Int {
            lines.append("disconnected=\(disconnected)")
        }
        guard listParticipants else { return lines.joined(separator: "\n") }
        for row in state["participants"] as? [[String: Any]] ?? [] {
            let id = row["id"] as? String ?? "?"
            let kind = row["device_kind"] as? String ?? "unknown"
            let name = (row["display_name"] as? String) ?? (row["device_name"] as? String) ?? ""
            let viewport = (row["viewport"] as? [String: Any]).flatMap { v -> String? in
                guard let c = v["cols"] as? Int, let r = v["rows"] as? Int else { return nil }
                return "\(c)x\(r)"
            } ?? "-"
            var flags: [String] = []
            if id == selfID { flags.append("self") }
            if owners.contains(id) { flags.append("owner") }
            if row["counts"] as? Bool == false { flags.append("viewer") }
            let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: ","))]"
            lines.append("  \(id)  \(kind)  \(viewport)  \(name)\(suffix)")
        }
        return lines.joined(separator: "\n")
    }
}
