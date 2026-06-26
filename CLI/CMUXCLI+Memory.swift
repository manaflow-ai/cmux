import Foundation

extension CMUXCLI {
    private struct MemoryCommandOptions {
        let includeAllWindows: Bool
        let workspaceHandle: String?
        let jsonOutput: Bool
        let topGroupLimit: Int
    }

    func runMemoryCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseMemoryCommandOptions(commandArgs)
        let payload = try buildMemoryPayload(options: options, client: client)
        if jsonOutput || options.jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(renderMemoryText(payload: payload, idFormat: idFormat))
        }
    }

    private func parseMemoryCommandOptions(_ args: [String]) throws -> MemoryCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: String(localized: "cli.memory.error.workspaceRequiresValue", defaultValue: "memory requires --workspace <id|ref|index>"))
        }
        let (groupsOpt, rem1) = parseOption(rem0, name: "--groups")
        if rem1.contains("--groups") {
            throw CLIError(message: String(localized: "cli.memory.error.groupsRequiresValue", defaultValue: "memory requires --groups <count>"))
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
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.memory.error.unknownFlag", defaultValue: "memory: unknown flag '%@'. Known flags: --all --workspace <id|ref|index> --groups <count> --json"),
                unknown
            ))
        }
        if let extra = remaining.first {
            throw CLIError(message: String.localizedStringWithFormat(
                String(localized: "cli.memory.error.unexpectedArgument", defaultValue: "memory: unexpected argument '%@'"),
                extra
            ))
        }

        let topGroupLimit: Int
        if let groupsOpt {
            guard let parsed = Int(groupsOpt), (1...100).contains(parsed) else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(localized: "cli.memory.error.invalidGroups", defaultValue: "memory: invalid --groups value '%@'. Use an integer from 1 to 100"),
                    groupsOpt
                ))
            }
            topGroupLimit = parsed
        } else {
            topGroupLimit = 12
        }

        return MemoryCommandOptions(
            includeAllWindows: includeAll,
            workspaceHandle: workspaceOpt,
            jsonOutput: jsonOutput,
            topGroupLimit: topGroupLimit
        )
    }

    private func buildMemoryPayload(
        options: MemoryCommandOptions,
        client: SocketClient
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "all_windows": options.includeAllWindows,
            "top_group_limit": options.topGroupLimit
        ]
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client) else {
                throw CLIError(message: String(format: String(
                    localized: "cli.memory.error.invalidWorkspace",
                    defaultValue: "memory: invalid workspace handle '%@'"
                ), workspaceRaw))
            }
            params["workspace_id"] = workspaceHandle
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        do {
            return try client.sendV2(method: "system.memory", params: params)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            throw CLIError(message: String(localized: "cli.memory.error.diagnosticsUnsupported", defaultValue: "cmux memory requires a running cmux build that supports memory diagnostics"))
        }
    }

    private func renderMemoryText(
        payload: [String: Any],
        idFormat: CLIIDFormat
    ) -> String {
        guard let diagnostic = payload["memory_diagnostic"] as? [String: Any] else {
            return String(localized: "cli.memory.output.noDiagnostic", defaultValue: "No memory diagnostic available")
        }

        let app = diagnostic["app"] as? [String: Any] ?? [:]
        let children = diagnostic["children"] as? [String: Any] ?? [:]
        let appName = topLabelText(app["name"] as? String)
        let appPID = topInt(app["pid"]).map(String.init) ?? "?"
        let appFootprint = topInt64(app["physical_footprint_bytes"])
        let appRSS = topInt64(app["resident_bytes"])
        let childRSS = topInt64(children["recursive_rss_bytes"])
        let childCount = topInt(children["process_count"]) ?? 0
        let summary = topLabelText(diagnostic["summary"] as? String)

        var lines: [String] = []
        if !summary.isEmpty {
            lines.append(summary)
            lines.append("")
        }
        lines.append(String(localized: "cli.memory.output.appHeader", defaultValue: "APP"))
        lines.append("  \(appName.isEmpty ? "cmux" : appName) pid=\(appPID)")
        lines.append(String.localizedStringWithFormat(
            String(localized: "cli.memory.output.appFootprint", defaultValue: "  footprint %@"),
            formatBytes(appFootprint)
        ))
        lines.append(String.localizedStringWithFormat(
            String(localized: "cli.memory.output.appRSS", defaultValue: "  rss       %@"),
            formatBytes(appRSS)
        ))
        lines.append("")
        lines.append(String(localized: "cli.memory.output.childrenHeader", defaultValue: "CHILD PROCESSES"))
        lines.append(String.localizedStringWithFormat(
            String(localized: "cli.memory.output.recursiveRSS", defaultValue: "  recursive RSS %@ across %@"),
            formatBytes(childRSS),
            memoryProcessCountText(childCount)
        ))

        let groups = children["groups"] as? [[String: Any]] ?? []
        guard !groups.isEmpty else {
            lines.append(String(localized: "cli.memory.output.noChildGroups", defaultValue: "  no child process groups"))
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append(String(localized: "cli.memory.output.topGroupsHeader", defaultValue: "TOP CHILD GROUPS"))
        lines.append(String(localized: "cli.memory.output.topGroupsColumns", defaultValue: "      RSS  PROC  COMMAND                    ATTRIBUTION"))
        for group in groups {
            let rss = padLeft(formatBytes(topInt64(group["rss_bytes"])), width: 9)
            let processCount = padLeft(String(topInt(group["process_count"]) ?? 0), width: 5)
            let name = topLabelText(group["name"] as? String)
            let command = name.padding(toLength: 26, withPad: " ", startingAt: 0)
            let attribution = memoryAttributionText(group["top_attribution"], idFormat: idFormat)
            lines.append("\(rss) \(processCount)  \(command) \(attribution)")
        }

        return lines.joined(separator: "\n")
    }

    private func memoryProcessCountText(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "cli.memory.output.processCount.one", defaultValue: "1 process")
        }
        return String.localizedStringWithFormat(
            String(localized: "cli.memory.output.processCount.other", defaultValue: "%lld processes"),
            count
        )
    }

    private func memoryAttributionText(_ raw: Any?, idFormat: CLIIDFormat) -> String {
        guard let attribution = raw as? [String: Any] else {
            return String(localized: "cli.memory.output.unattributed", defaultValue: "unattributed")
        }

        var parts: [String] = []
        if let workspace = memoryAttributionHandle(attribution, prefix: "workspace", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.workspaceAttribution", defaultValue: "workspace %@"),
                workspace
            ))
        }
        if let pane = memoryAttributionHandle(attribution, prefix: "pane", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.paneAttribution", defaultValue: "pane %@"),
                pane
            ))
        }
        if let surface = memoryAttributionHandle(attribution, prefix: "surface", idFormat: idFormat) {
            parts.append(String.localizedStringWithFormat(
                String(localized: "cli.memory.output.surfaceAttribution", defaultValue: "surface %@"),
                surface
            ))
        }
        return parts.isEmpty ? String(localized: "cli.memory.output.unattributed", defaultValue: "unattributed") : parts.joined(separator: " / ")
    }

    private func memoryAttributionHandle(
        _ attribution: [String: Any],
        prefix: String,
        idFormat: CLIIDFormat
    ) -> String? {
        let ref = topLabelText(attribution["\(prefix)_ref"] as? String)
        let id = topLabelText(attribution["\(prefix)_id"] as? String)
        switch idFormat {
        case .refs:
            return ref.isEmpty ? (id.isEmpty ? nil : id) : ref
        case .uuids:
            return id.isEmpty ? (ref.isEmpty ? nil : ref) : id
        case .both:
            let values = [ref, id].filter { !$0.isEmpty }
            return values.isEmpty ? nil : values.joined(separator: " ")
        }
    }
}
