import Foundation

extension CMUXCLI {
    struct MemoryWorkspaceSample {
        let sampledAt: Date
        let windowId: String?
        let windowRef: String?
        let workspaceId: String
        let workspaceRef: String?
        let workspaceTitle: String
        let cpuPercent: Double
        let memoryPercent: Double
        let residentBytes: Int64
        let virtualBytes: Int64
        let processCount: Int
        let topProcessNames: [String]

        var payload: [String: Any] {
            [
                "sampled_at": Self.iso8601(sampledAt),
                "approximate": true,
                "window_id": windowId ?? NSNull(),
                "window_ref": windowRef ?? NSNull(),
                "workspace_id": workspaceId,
                "workspace_ref": workspaceRef ?? NSNull(),
                "workspace_title": workspaceTitle,
                "cpu_percent": cpuPercent,
                "memory_percent": memoryPercent,
                "resident_bytes": residentBytes,
                "virtual_bytes": virtualBytes,
                "process_count": processCount,
                "top_process_names": topProcessNames
            ]
        }

        private static func iso8601(_ date: Date) -> String {
            ISO8601DateFormatter().string(from: date)
        }
    }

    func buildMemorySamples(
        options: MemoryCurrentCommandOptions,
        client: SocketClient
    ) throws -> [MemoryWorkspaceSample] {
        let payload = try buildMemoryTopPayload(
            workspaceHandle: options.workspaceHandle,
            client: client
        )
        var samples = memoryWorkspaceSamples(from: payload)
        samples.sort {
            if $0.residentBytes != $1.residentBytes {
                return $0.residentBytes > $1.residentBytes
            }
            return ($0.workspaceRef ?? $0.workspaceId) < ($1.workspaceRef ?? $1.workspaceId)
        }
        return samples
    }

    func limitedMemorySamples(_ samples: [MemoryWorkspaceSample], limit: Int?) -> [MemoryWorkspaceSample] {
        guard let limit else { return samples }
        return Array(samples.prefix(max(1, limit)))
    }

    func buildMemoryTopPayload(
        workspaceHandle: String?,
        client: SocketClient
    ) throws -> [String: Any] {
        var params: [String: Any] = [
            "all_windows": true,
            "include_processes": true
        ]
        if let workspaceHandle {
            guard let normalized = try normalizeWorkspaceHandle(workspaceHandle, client: client) else {
                throw CLIError(message: "Invalid workspace handle")
            }
            params["workspace_id"] = normalized
        }
        do {
            return try client.sendV2(method: "system.top", params: params, responseTimeout: 30)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            throw CLIError(message: String(
                localized: "cli.memory.error.telemetrySupportRequired",
                defaultValue: "cmux memory requires a running cmux build with memory telemetry support"
            ))
        }
    }

    func memoryWorkspaceSamples(from payload: [String: Any]) -> [MemoryWorkspaceSample] {
        let sampledAt = memorySampleDate(from: payload)
        let windows = payload["windows"] as? [[String: Any]] ?? []
        var samples: [MemoryWorkspaceSample] = []
        for window in windows {
            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                let resources = workspace["resources"] as? [String: Any] ?? [:]
                samples.append(
                    MemoryWorkspaceSample(
                        sampledAt: sampledAt,
                        windowId: window["id"] as? String,
                        windowRef: window["ref"] as? String,
                        workspaceId: (workspace["id"] as? String) ?? "",
                        workspaceRef: workspace["ref"] as? String,
                        workspaceTitle: topLabelText(workspace["title"] as? String),
                        cpuPercent: topDouble(resources["cpu_percent"]),
                        memoryPercent: topDouble(resources["memory_percent"] ?? resources["percent_mem"]),
                        residentBytes: topInt64(resources["resident_bytes"]),
                        virtualBytes: topInt64(resources["virtual_bytes"]),
                        processCount: topInt(resources["process_count"]) ?? 0,
                        topProcessNames: topMemoryProcessNames(in: workspace)
                    )
                )
            }
        }
        return samples.filter { !$0.workspaceId.isEmpty }
    }

    func memorySampleDate(from payload: [String: Any]) -> Date {
        if let sample = payload["sample"] as? [String: Any],
           let raw = sample["sampled_at"] as? String,
           let date = ISO8601DateFormatter().date(from: raw) {
            return date
        }
        return .now
    }

    func topMemoryProcessNames(in workspace: [String: Any]) -> [String] {
        var residentBytesByName: [String: Int64] = [:]
        collectMemoryProcessNames(fromProcessesIn: workspace, into: &residentBytesByName)
        for tag in workspace["tags"] as? [[String: Any]] ?? [] {
            collectMemoryProcessNames(fromProcessesIn: tag, into: &residentBytesByName)
        }
        for pane in workspace["panes"] as? [[String: Any]] ?? [] {
            collectMemoryProcessNames(fromProcessesIn: pane, into: &residentBytesByName)
            for surface in pane["surfaces"] as? [[String: Any]] ?? [] {
                collectMemoryProcessNames(fromProcessesIn: surface, into: &residentBytesByName)
                for webview in surface["webviews"] as? [[String: Any]] ?? [] {
                    collectMemoryProcessNames(fromProcessesIn: webview, into: &residentBytesByName)
                }
            }
        }
        return residentBytesByName
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(5)
            .map(\.key)
    }

    func collectMemoryProcessNames(
        fromProcessesIn node: [String: Any],
        into residentBytesByName: inout [String: Int64]
    ) {
        let processes = node["processes"] as? [[String: Any]] ?? []
        for process in processes {
            collectMemoryProcessName(from: process, into: &residentBytesByName)
        }
    }

    func collectMemoryProcessName(
        from process: [String: Any],
        into residentBytesByName: inout [String: Int64]
    ) {
        let name = topLabelText(process["name"] as? String)
        if !name.isEmpty {
            let resources = process["resources"] as? [String: Any] ?? [:]
            residentBytesByName[name, default: 0] += topInt64(resources["resident_bytes"])
        }
        for child in process["children"] as? [[String: Any]] ?? [] {
            collectMemoryProcessName(from: child, into: &residentBytesByName)
        }
    }
}
