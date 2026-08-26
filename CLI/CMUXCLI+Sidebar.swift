import Foundation

extension CMUXCLI {
    func runSidebarCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput inheritedJSONOutput: Bool,
        windowOverride: String?
    ) throws {
        var args = commandArgs
        var jsonOutput = inheritedJSONOutput
        var explicitAll = false
        args.removeAll { arg in
            if arg == "--json" {
                jsonOutput = true
                return true
            }
            if arg == "--all" {
                explicitAll = true
                return true
            }
            return false
        }

        guard let action = args.first?.lowercased() else {
            throw CLIError(
                message: String(
                    localized: "cli.sidebar.error.missingCommand",
                    defaultValue: "sidebar requires a subcommand: validate, render, reload, select, or open"
                )
            )
        }

        let remaining = Array(args.dropFirst())
        let method: String
        var params: [String: Any] = [:]

        switch action {
        case "validate", "reload":
            guard remaining.count <= 1 else {
                throw CLIError(
                    message: String(
                        format: String(
                            localized: "cli.sidebar.error.unexpectedArguments",
                            defaultValue: "sidebar %@ accepts at most one sidebar name"
                        ),
                        action
                    )
                )
            }
            guard !(explicitAll && !remaining.isEmpty) else {
                throw CLIError(
                    message: String(
                        format: String(
                            localized: "cli.sidebar.error.allWithName",
                            defaultValue: "sidebar %@: use either --all or a sidebar name, not both"
                        ),
                        action
                    )
                )
            }
            if let name = remaining.first { params["name"] = name }
            method = action == "validate" ? "sidebar.custom.validate" : "sidebar.custom.reload"

        case "render":
            guard !explicitAll else {
                throw CLIError(
                    message: String(
                        localized: "cli.sidebar.error.renderAll",
                        defaultValue: "sidebar render requires one sidebar name and does not support --all"
                    )
                )
            }
            let (widthRaw, afterWidth) = parseOption(remaining, name: "--width")
            let (heightRaw, afterHeight) = parseOption(afterWidth, name: "--height")
            let (outputRaw, positional) = parseOption(afterHeight, name: "--output")
            guard positional.count == 1, let name = positional.first, !name.hasPrefix("--") else {
                throw CLIError(
                    message: String(
                        localized: "cli.sidebar.error.renderUsage",
                        defaultValue: "Usage: cmux sidebar render <name> --width <n> --height <n> --output <path>"
                    )
                )
            }
            guard let widthRaw, let width = Int(widthRaw), width > 0,
                  let heightRaw, let height = Int(heightRaw), height > 0,
                  width <= 4096, height <= 4096 else {
                throw CLIError(
                    message: String(
                        localized: "cli.sidebar.error.renderSize",
                        defaultValue: "sidebar render requires --width and --height values between 1 and 4096"
                    )
                )
            }
            guard let outputRaw, !outputRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(
                    message: String(
                        localized: "cli.sidebar.error.renderOutput",
                        defaultValue: "sidebar render requires --output <path>"
                    )
                )
            }
            params["name"] = name
            params["width"] = width
            params["height"] = height
            params["output"] = outputRaw
            method = "sidebar.custom.render"

        case "select", "open":
            guard !explicitAll else {
                throw CLIError(
                    message: String(format: String(localized: "cli.sidebar.error.namedActionAll", defaultValue: "sidebar %@ does not support --all"), action)
                )
            }
            let nameArgs = action == "open"
                ? parseOption(parseOption(remaining, name: "--workspace").1, name: "--window").1
                : remaining
            guard nameArgs.count == 1 else {
                throw CLIError(
                    message: String(format: String(localized: "cli.sidebar.error.namedActionRequiresName", defaultValue: "sidebar %@ requires one sidebar name"), action)
                )
            }
            params["name"] = nameArgs[0]
            if action == "open" {
                params["focus"] = true
                let winId = try normalizeWindowHandle(sidebarWindowFromArgsOrOverride(remaining, windowOverride: windowOverride), client: client)
                if let winId { params["window_id"] = winId }
                let wsId = try normalizeWorkspaceHandle(
                    sidebarWorkspaceFromArgsOrEnv(remaining, windowOverride: windowOverride),
                    client: client,
                    windowHandle: winId
                )
                if let wsId { params["workspace_id"] = wsId }
            }
            method = action == "select" ? "sidebar.custom.select" : "sidebar.custom.open"

        default:
            throw CLIError(
                message: String(
                    format: String(
                        localized: "cli.sidebar.error.unknownCommand",
                        defaultValue: "Unknown sidebar command '%@'"
                    ),
                    action
                )
            )
        }

        let payload = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(payload))
        } else if action == "render" {
            printSidebarRenderReport(payload)
        } else {
            printSidebarReport(payload, action: action)
        }

        if renderSidebarIntValue(payload["error_count"]) > 0 {
            exit(1)
        }
    }

    private func printSidebarRenderReport(_ payload: [String: Any]) {
        let name = (payload["name"] as? String) ?? "(unknown)"
        guard renderSidebarBoolValue(payload["render_ok"]) else {
            let error = (payload["error"] as? String)
                ?? String(localized: "cli.sidebar.unknownError", defaultValue: "Unknown error")
            print(String(
                format: String(localized: "cli.sidebar.render.error", defaultValue: "ERROR %@: %@"),
                name,
                error
            ))
            return
        }

        let path = (payload["artifact_path"] as? String) ?? ""
        let width = renderSidebarIntValue(payload["width"])
        let height = renderSidebarIntValue(payload["height"])
        let pixels = renderSidebarIntValue(payload["visible_pixel_count"])
        print(String(
            format: String(
                localized: "cli.sidebar.render.ok",
                defaultValue: "Rendered %@ at %dx%d (%d visible pixels) -> %@"
            ),
            name,
            width,
            height,
            pixels,
            path
        ))
    }

    private func printSidebarReport(_ payload: [String: Any], action: String) {
        let sidebars = payload["sidebars"] as? [[String: Any]] ?? []
        if sidebars.isEmpty {
            print(String(localized: "cli.sidebar.noSidebars", defaultValue: "No custom sidebars found."))
        }
        for sidebar in sidebars {
            let name = (sidebar["name"] as? String) ?? "(unknown)"
            let path = (sidebar["path"] as? String) ?? ""
            let kind = (sidebar["kind"] as? String) ?? ""
            let ok = renderSidebarBoolValue(sidebar["ok"])
            if ok {
                print(String(
                    format: String(localized: "cli.sidebar.report.ok", defaultValue: "OK %@ [%@] %@"),
                    name,
                    kind,
                    path
                ))
            } else {
                let error = (sidebar["error"] as? String)
                    ?? String(localized: "cli.sidebar.unknownError", defaultValue: "Unknown error")
                print(String(
                    format: String(localized: "cli.sidebar.report.error", defaultValue: "ERROR %@ [%@] %@: %@"),
                    name,
                    kind,
                    path,
                    error
                ))
            }
        }

        let validCount = renderSidebarIntValue(payload["valid_count"])
        let errorCount = renderSidebarIntValue(payload["error_count"])
        if action == "reload" {
            let reloadedCount = renderSidebarIntValue(payload["reloaded_count"])
            print(String(
                format: String(localized: "cli.sidebar.report.reloadSummary", defaultValue: "Reloaded %d valid sidebars. %d valid, %d invalid."),
                reloadedCount,
                validCount,
                errorCount
            ))
        } else if action == "select", let selectedName = payload["selected_name"] as? String {
            print(String(
                format: String(localized: "cli.sidebar.report.selected", defaultValue: "Selected %@."),
                selectedName
            ))
        } else if action == "open", let openedName = payload["opened_name"] as? String {
            let surface = (payload["surface_ref"] as? String) ?? (payload["surface_id"] as? String) ?? ""
            print(String(
                format: String(localized: "cli.sidebar.report.opened", defaultValue: "Opened %@ as pane %@."),
                openedName,
                surface
            ))
        } else {
            print(String(
                format: String(localized: "cli.sidebar.report.summary", defaultValue: "%d valid, %d invalid."),
                validCount,
                errorCount
            ))
        }
    }

    private func renderSidebarIntValue(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return 0
    }

    private func renderSidebarBoolValue(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            return ["1", "true", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }

    private func sidebarWorkspaceFromArgsOrEnv(_ args: [String], windowOverride: String?) -> String? {
        if let explicit = optionValue(args, name: "--workspace") { return explicit }
        if windowOverride != nil || optionValue(args, name: "--window") != nil { return nil }
        return ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
    }

    private func sidebarWindowFromArgsOrOverride(_ args: [String], windowOverride: String?) -> String? {
        optionValue(args, name: "--window") ?? windowOverride
    }
}
