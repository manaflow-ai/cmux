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


// MARK: - cmux tree command
extension CMUXCLI {
    private struct TreeCommandOptions {
        let includeAllWindows: Bool
        let workspaceHandle: String?
        let windowHandle: String?
        let jsonOutput: Bool
    }

    private struct TreePath {
        let windowHandle: String?
        let workspaceHandle: String?
        let paneHandle: String?
        let surfaceHandle: String?
    }

    func runTreeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let options = try parseTreeCommandOptions(commandArgs)
        let payload = try buildTreePayload(options: options, client: client)
        if jsonOutput || options.jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let windows = payload["windows"] as? [[String: Any]] ?? []
            print(renderTreeText(windows: windows, idFormat: idFormat))
        }
    }

    private func parseTreeCommandOptions(_ args: [String]) throws -> TreeCommandOptions {
        let (workspaceOpt, rem0) = parseOption(args, name: "--workspace")
        if rem0.contains("--workspace") {
            throw CLIError(message: "tree requires --workspace <id|ref|index>")
        }
        let (windowOpt, rem1) = parseOption(rem0, name: "--window")
        if rem1.contains("--window") {
            throw CLIError(message: "tree requires --window <id|ref|index>")
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
            throw CLIError(message: "tree: unknown flag '\(unknown)'. Known flags: --all --workspace <id|ref|index> --window <id|ref|index> --json")
        }
        if let extra = remaining.first {
            throw CLIError(message: "tree: unexpected argument '\(extra)'")
        }

        return TreeCommandOptions(includeAllWindows: includeAll, workspaceHandle: workspaceOpt, windowHandle: windowOpt, jsonOutput: jsonOutput)
    }

    private func buildTreePayload(
        options: TreeCommandOptions,
        client: SocketClient
    ) throws -> [String: Any] {
        var params: [String: Any] = ["all_windows": options.includeAllWindows]
        let windowHandle = try normalizeWindowHandle(options.windowHandle, client: client)
        if options.includeAllWindows, windowHandle != nil {
            throw CLIError(message: "tree: --window cannot be combined with --all")
        }
        if let windowHandle {
            params["window_id"] = windowHandle
        }
        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle) else {
                throw CLIError(message: "Invalid workspace handle")
            }
            params["workspace_id"] = workspaceHandle
        }
        if let caller = treeCallerContextFromEnvironment() {
            params["caller"] = caller
        }

        do {
            let payload = try client.sendV2(method: "system.tree", params: params)
            return treePayloadWithMarkers(payload)
        } catch let error as CLIError where error.message.hasPrefix("method_not_found:") {
            // Back-compat fallback for older servers that don't support system.tree.
            return try buildLegacyTreePayload(options: options, params: params, client: client)
        }
    }

    private func buildLegacyTreePayload(
        options: TreeCommandOptions,
        params: [String: Any],
        client: SocketClient
    ) throws -> [String: Any] {
        var identifyParams: [String: Any] = [:]
        let windowHandle = params["window_id"] as? String
        if let windowHandle {
            identifyParams["window_id"] = windowHandle
        }
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }

        let identifyPayload = try client.sendV2(method: "system.identify", params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: focused)
        let windows = try buildTreeWindowNodes(
            options: options,
            windowHandle: windowHandle,
            activePath: activePath,
            client: client
        )

        return treePayloadWithMarkers([
            "active": focused.isEmpty ? NSNull() : focused,
            "caller": caller.isEmpty ? NSNull() : caller,
            "windows": windows
        ])
    }

    private func buildTreeWindowNodes(
        options: TreeCommandOptions,
        windowHandle: String?,
        activePath: TreePath,
        client: SocketClient
    ) throws -> [[String: Any]] {
        let windowsPayload = try client.sendV2(method: "window.list")
        let allWindows = windowsPayload["windows"] as? [[String: Any]] ?? []

        if let workspaceRaw = options.workspaceHandle {
            guard let workspaceHandle = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: windowHandle) else {
                throw CLIError(message: "Invalid workspace handle")
            }

            var workspaceParams: [String: Any] = ["workspace_id": workspaceHandle]
            if let windowHandle {
                workspaceParams["window_id"] = windowHandle
            }
            let workspaceListPayload = try client.sendV2(method: "workspace.list", params: workspaceParams)
            let workspaceWindowHandle = (workspaceListPayload["window_ref"] as? String) ?? (workspaceListPayload["window_id"] as? String)
            let explicitWindow = windowHandle.flatMap { handle in
                allWindows.first(where: { treeItemMatchesHandle($0, handle: handle) })
            }
            let window = explicitWindow
                ?? allWindows.first(where: { treeItemMatchesHandle($0, handle: workspaceWindowHandle) })
                ?? treeFallbackWindow(from: workspaceListPayload)

            let workspaces = workspaceListPayload["workspaces"] as? [[String: Any]] ?? []
            if workspaces.isEmpty {
                throw CLIError(message: "Workspace not found")
            }
            let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
            var node = window
            let isActiveWindow = treeItemMatchesHandle(node, handle: activePath.windowHandle)
            node["current"] = isActiveWindow
            node["active"] = isActiveWindow
            node["workspaces"] = workspaceNodes
            node["workspace_count"] = workspaceNodes.count
            return [node]
        }

        let targetWindows: [[String: Any]]
        if options.includeAllWindows {
            targetWindows = allWindows
        } else if let windowHandle {
            targetWindows = allWindows.filter { treeItemMatchesHandle($0, handle: windowHandle) }
            if targetWindows.isEmpty {
                throw CLIError(message: "Window not found: \(windowHandle)")
            }
        } else if let currentWindowHandle = activePath.windowHandle {
            let currentOnly = allWindows.filter { treeItemMatchesHandle($0, handle: currentWindowHandle) }
            targetWindows = currentOnly.isEmpty ? Array(allWindows.prefix(1)) : currentOnly
        } else {
            targetWindows = Array(allWindows.prefix(1))
        }

        return try targetWindows.map {
            try buildTreeWindowNode(
                window: $0,
                activePath: activePath,
                client: client
            )
        }
    }

    private func treeFallbackWindow(from payload: [String: Any]) -> [String: Any] {
        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
        let selectedWorkspace = workspaces.first(where: { ($0["selected"] as? Bool) == true })
        return [
            "id": payload["window_id"] ?? NSNull(),
            "ref": payload["window_ref"] ?? NSNull(),
            "index": 0,
            "key": false,
            "visible": true,
            "workspace_count": workspaces.count,
            "selected_workspace_id": selectedWorkspace?["id"] ?? NSNull(),
            "selected_workspace_ref": selectedWorkspace?["ref"] ?? NSNull(),
        ]
    }

    private func buildTreeWindowNode(
        window: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceParams: [String: Any] = [:]
        if let windowHandle = treeItemHandle(window) {
            workspaceParams["window_id"] = windowHandle
        }
        let workspacePayload = try client.sendV2(method: "workspace.list", params: workspaceParams)
        let workspaces = workspacePayload["workspaces"] as? [[String: Any]] ?? []
        let workspaceNodes = try workspaces.map { try buildTreeWorkspaceNode(workspace: $0, activePath: activePath, client: client) }
        var windowNode = window
        let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
        windowNode["current"] = isActiveWindow
        windowNode["active"] = isActiveWindow
        windowNode["workspaces"] = workspaceNodes
        windowNode["workspace_count"] = workspaceNodes.count
        return windowNode
    }

    private func buildTreeWorkspaceNode(
        workspace: [String: Any],
        activePath: TreePath,
        client: SocketClient
    ) throws -> [String: Any] {
        var workspaceNode = workspace
        guard let workspaceHandle = treeItemHandle(workspace) else {
            workspaceNode["panes"] = []
            return workspaceNode
        }

        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceHandle])
        let surfacePayload = try client.sendV2(method: "surface.list", params: ["workspace_id": workspaceHandle])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        let surfaces = surfacePayload["surfaces"] as? [[String: Any]] ?? []
        let browserURLsByHandle = fetchTreeBrowserURLs(
            workspaceHandle: workspaceHandle,
            surfaces: surfaces,
            client: client
        )

        var surfacesByPane: [String: [[String: Any]]] = [:]
        for surface in surfaces {
            var surfaceNode = surface
            if surfaceNode["selected"] == nil {
                surfaceNode["selected"] = (surfaceNode["selected_in_pane"] as? Bool) == true
            }
            surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)

            let surfaceType = ((surfaceNode["type"] as? String) ?? "").lowercased()
            if surfaceType == "browser",
               let url = treeBrowserURL(surface: surfaceNode, urlsByHandle: browserURLsByHandle),
               !url.isEmpty {
                surfaceNode["url"] = url
            } else {
                surfaceNode["url"] = NSNull()
            }

            guard let paneHandle = treeRelatedHandle(surfaceNode, refKey: "pane_ref", idKey: "pane_id") else {
                continue
            }
            surfacesByPane[paneHandle, default: []].append(surfaceNode)
        }

        for paneHandle in surfacesByPane.keys {
            surfacesByPane[paneHandle]?.sort {
                let lhs = intFromAny($0["index_in_pane"]) ?? intFromAny($0["index"]) ?? Int.max
                let rhs = intFromAny($1["index_in_pane"]) ?? intFromAny($1["index"]) ?? Int.max
                return lhs < rhs
            }
        }

        let paneNodes: [[String: Any]] = panes.map { pane in
            var paneNode = pane
            paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)
            if let paneHandle = treeItemHandle(paneNode) {
                paneNode["surfaces"] = surfacesByPane[paneHandle] ?? []
            } else {
                paneNode["surfaces"] = []
            }
            return paneNode
        }

        workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)
        workspaceNode["panes"] = paneNodes
        return workspaceNode
    }

    private func treeItemHandle(_ item: [String: Any]) -> String? {
        if let ref = item["ref"] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func treeRelatedHandle(_ item: [String: Any], refKey: String, idKey: String) -> String? {
        if let ref = item[refKey] as? String, !ref.isEmpty {
            return ref
        }
        if let id = item[idKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func parseTreePath(payload: [String: Any]) -> TreePath {
        return TreePath(
            windowHandle: treeRelatedHandle(payload, refKey: "window_ref", idKey: "window_id"),
            workspaceHandle: treeRelatedHandle(payload, refKey: "workspace_ref", idKey: "workspace_id"),
            paneHandle: treeRelatedHandle(payload, refKey: "pane_ref", idKey: "pane_id"),
            surfaceHandle: treeRelatedHandle(payload, refKey: "surface_ref", idKey: "surface_id")
        )
    }

    func treeCallerContextFromEnvironment() -> [String: Any]? {
        let env = ProcessInfo.processInfo.environment
        let workspaceRaw = env["CMUX_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceRaw = env["CMUX_SURFACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var caller: [String: Any] = [:]
        if let workspaceRaw, !workspaceRaw.isEmpty {
            caller["workspace_id"] = workspaceRaw
        }
        if let surfaceRaw, !surfaceRaw.isEmpty {
            caller["surface_id"] = surfaceRaw
        }
        return caller.isEmpty ? nil : caller
    }

    private func treePayloadWithMarkers(_ payload: [String: Any]) -> [String: Any] {
        let active = payload["active"] as? [String: Any] ?? [:]
        let caller = payload["caller"] as? [String: Any] ?? [:]
        let activePath = parseTreePath(payload: active)
        let callerPath = parseTreePath(payload: caller)
        var result = payload
        let windows = payload["windows"] as? [[String: Any]] ?? []
        result["windows"] = treeApplyMarkers(windows: windows, activePath: activePath, callerPath: callerPath)
        if result["active"] == nil {
            result["active"] = active.isEmpty ? NSNull() : active
        }
        if result["caller"] == nil {
            result["caller"] = caller.isEmpty ? NSNull() : caller
        }
        return result
    }

    private func treeApplyMarkers(
        windows: [[String: Any]],
        activePath: TreePath,
        callerPath: TreePath
    ) -> [[String: Any]] {
        return windows.map { window in
            var windowNode = window
            let isActiveWindow = treeItemMatchesHandle(windowNode, handle: activePath.windowHandle)
            windowNode["current"] = isActiveWindow
            windowNode["active"] = isActiveWindow

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            let workspaceNodes = workspaces.map { workspace in
                var workspaceNode = workspace
                workspaceNode["active"] = treeItemMatchesHandle(workspaceNode, handle: activePath.workspaceHandle)

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                let paneNodes = panes.map { pane in
                    var paneNode = pane
                    paneNode["active"] = treeItemMatchesHandle(paneNode, handle: activePath.paneHandle)

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    paneNode["surfaces"] = surfaces.map { surface in
                        var surfaceNode = surface
                        surfaceNode["active"] = treeItemMatchesHandle(surfaceNode, handle: activePath.surfaceHandle)
                        surfaceNode["here"] = treeItemMatchesHandle(surfaceNode, handle: callerPath.surfaceHandle)
                        return surfaceNode
                    }
                    return paneNode
                }

                workspaceNode["panes"] = paneNodes
                return workspaceNode
            }

            windowNode["workspaces"] = workspaceNodes
            return windowNode
        }
    }

    private func fetchTreeBrowserURLs(
        workspaceHandle: String,
        surfaces: [[String: Any]],
        client: SocketClient
    ) -> [String: String] {
        let hasBrowserSurfaces = surfaces.contains {
            (($0["type"] as? String) ?? "").lowercased() == "browser"
        }
        guard hasBrowserSurfaces else { return [:] }

        if let payload = try? client.sendV2(
            method: "browser.tab.list",
            params: ["workspace_id": workspaceHandle]
        ) {
            let tabs = payload["tabs"] as? [[String: Any]] ?? []
            var urlByHandle: [String: String] = [:]
            for tab in tabs {
                guard let url = tab["url"] as? String, !url.isEmpty else { continue }
                if let id = tab["id"] as? String, !id.isEmpty {
                    urlByHandle[id] = url
                }
                if let ref = tab["ref"] as? String, !ref.isEmpty {
                    urlByHandle[ref] = url
                }
            }
            return urlByHandle
        }

        // Fallback for older servers that may not support browser.tab.list.
        var fallbackURLs: [String: String] = [:]
        for surface in surfaces {
            guard ((surface["type"] as? String) ?? "").lowercased() == "browser" else { continue }
            guard let surfaceHandle = treeItemHandle(surface) else { continue }
            guard let payload = try? client.sendV2(
                method: "browser.url.get",
                params: ["workspace_id": workspaceHandle, "surface_id": surfaceHandle]
            ),
            let url = payload["url"] as? String,
            !url.isEmpty else {
                continue
            }
            fallbackURLs[surfaceHandle] = url
            if let id = surface["id"] as? String, !id.isEmpty {
                fallbackURLs[id] = url
            }
            if let ref = surface["ref"] as? String, !ref.isEmpty {
                fallbackURLs[ref] = url
            }
        }
        return fallbackURLs
    }

    private func treeBrowserURL(surface: [String: Any], urlsByHandle: [String: String]) -> String? {
        if let id = surface["id"] as? String, let url = urlsByHandle[id] {
            return url
        }
        if let ref = surface["ref"] as? String, let url = urlsByHandle[ref] {
            return url
        }
        if let handle = treeItemHandle(surface), let url = urlsByHandle[handle] {
            return url
        }
        return nil
    }

    private func treeItemMatchesHandle(_ item: [String: Any], handle: String?) -> Bool {
        guard let handle = handle?.trimmingCharacters(in: .whitespacesAndNewlines), !handle.isEmpty else {
            return false
        }
        return (item["id"] as? String) == handle || (item["ref"] as? String) == handle
    }

    private func renderTreeText(windows: [[String: Any]], idFormat: CLIIDFormat) -> String {
        guard !windows.isEmpty else { return "No windows" }

        var lines: [String] = []
        for window in windows {
            lines.append(treeWindowLabel(window, idFormat: idFormat))

            let workspaces = window["workspaces"] as? [[String: Any]] ?? []
            for (workspaceIndex, workspace) in workspaces.enumerated() {
                let workspaceIsLast = workspaceIndex == workspaces.count - 1
                let workspaceBranch = workspaceIsLast ? "└── " : "├── "
                let workspaceIndent = workspaceIsLast ? "    " : "│   "
                lines.append("\(workspaceBranch)\(treeWorkspaceLabel(workspace, idFormat: idFormat))")

                let panes = workspace["panes"] as? [[String: Any]] ?? []
                for (paneIndex, pane) in panes.enumerated() {
                    let paneIsLast = paneIndex == panes.count - 1
                    let paneBranch = paneIsLast ? "└── " : "├── "
                    let paneIndent = paneIsLast ? "    " : "│   "
                    lines.append("\(workspaceIndent)\(paneBranch)\(treePaneLabel(pane, idFormat: idFormat))")

                    let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
                    for (surfaceIndex, surface) in surfaces.enumerated() {
                        let surfaceIsLast = surfaceIndex == surfaces.count - 1
                        let surfaceBranch = surfaceIsLast ? "└── " : "├── "
                        lines.append("\(workspaceIndent)\(paneIndent)\(surfaceBranch)\(treeSurfaceLabel(surface, idFormat: idFormat))")
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func treeWindowLabel(_ window: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["window \(textHandle(window, idFormat: idFormat))"]
        if (window["current"] as? Bool) == true {
            parts.append("[current]")
        }
        if (window["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeWorkspaceLabel(_ workspace: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["workspace \(textHandle(workspace, idFormat: idFormat))"]
        let title = (workspace["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (workspace["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (workspace["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treePaneLabel(_ pane: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["pane \(textHandle(pane, idFormat: idFormat))"]
        if (pane["focused"] as? Bool) == true {
            parts.append("[focused]")
        }
        if (pane["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        return parts.joined(separator: " ")
    }

    private func treeSurfaceLabel(_ surface: [String: Any], idFormat: CLIIDFormat) -> String {
        let rawType = ((surface["type"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceType = rawType.isEmpty ? "unknown" : rawType
        var parts = ["surface \(textHandle(surface, idFormat: idFormat))", "[\(surfaceType)]"]
        let title = (surface["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            parts.append("\"\(title)\"")
        }
        if (surface["selected"] as? Bool) == true {
            parts.append("[selected]")
        }
        if (surface["active"] as? Bool) == true {
            parts.append("◀ active")
        }
        if (surface["here"] as? Bool) == true {
            parts.append("◀ here")
        }
        if let tty = surface["tty"] as? String, !tty.isEmpty {
            parts.append("tty=\(tty)")
        }
        if surfaceType.lowercased() == "browser",
           let url = surface["url"] as? String,
           !url.isEmpty {
            parts.append(url)
        }
        return parts.joined(separator: " ")
    }

}
