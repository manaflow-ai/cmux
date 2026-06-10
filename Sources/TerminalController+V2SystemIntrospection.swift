import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import CmuxSwiftRenderUI
import Carbon.HIToolbox
import CMUXMobileCore
import CMUXWorkstream
import Foundation
import Bonsplit
import WebKit


// MARK: - V2 system tree, top, and memory introspection
extension TerminalController {
    func v2SystemTree(params: [String: Any]) -> V2CallResult {
        let workspaceFilter = v2UUID(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        let routingResult = parseV2WindowRouting(params: params)
        if let error = routingResult.error { return error }
        guard let routing = routingResult.routing else {
            return .err(code: "internal_error", message: "Invalid window routing payload", data: nil)
        }

        var windowNodes: [[String: Any]] = []
        var workspaceFound = (workspaceFilter == nil)
        var windowFound = (routing.requestedWindowId == nil)

        v2MainSync {
            guard let app = AppDelegate.shared else { return }
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = routing.requestedWindowId ?? routing.focusedWindowId ?? summaries.first?.windowId

            for (windowIndex, summary) in summaries.enumerated() {
                if let requestedWindowId = routing.requestedWindowId, summary.windowId != requestedWindowId {
                    continue
                }
                windowFound = true
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = v2TreeWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windowNodes = [
                        v2TreeWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: [workspaceNode]
                        )
                    ]
                    workspaceFound = true
                    break
                }

                if !routing.includeAllWindows && summary.windowId != defaultWindowId {
                    continue
                }

                let workspaceNodesForWindow = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TreeWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }

                windowNodes.append(
                    v2TreeWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodesForWindow
                    )
                )
            }
        }

        if let requestedWindowId = routing.requestedWindowId, !windowFound {
            return v2WindowNotFoundResult(params: params, windowId: requestedWindowId)
        }
        if let workspaceFilter, !workspaceFound {
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: [
                    "workspace_id": workspaceFilter.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceFilter)
                ]
            )
        }

        return .ok([
            "active": routing.focused.isEmpty ? (NSNull() as Any) : routing.focused,
            "caller": routing.caller.isEmpty ? (NSNull() as Any) : routing.caller,
            "windows": windowNodes
        ])
    }

#if DEBUG
    func v2DebugSessionSnapshotBenchmark(params: [String: Any]) -> V2CallResult {
        let includeScrollback = v2Bool(params, "include_scrollback")
            ?? v2Bool(params, "scrollback")
            ?? false
        let persist = v2Bool(params, "persist") ?? true
        var payload: [String: Any]?
        // Snapshot capture walks AppKit, SwiftUI, and terminal-panel state, so this
        // DEBUG-only benchmark must run synchronously on the main thread.
        v2MainSync {
            payload = AppDelegate.shared?.debugBenchmarkSessionSnapshot(
                includeScrollback: includeScrollback,
                persist: persist
            )
        }
        guard let payload else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }

    func v2DebugSessionSnapshotSeedScrollback(params: [String: Any]) -> V2CallResult {
        let charactersPerTerminal = v2Int(params, "characters_per_terminal")
            ?? v2Int(params, "chars_per_terminal")
            ?? 0
        var payload: [String: Any]?
        // Synthetic scrollback seeding mutates workspace snapshot fallback state,
        // which is owned by the main-thread workspace graph.
        v2MainSync {
            payload = AppDelegate.shared?.debugSeedSessionSnapshotScrollback(
                charactersPerTerminal: charactersPerTerminal
            )
        }
        guard let payload else {
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        }
        return .ok(payload)
    }
#endif

    func taskManagerTopPayload(includeProcesses: Bool) async throws -> [String: Any] {
        v2RefreshKnownRefs()

        let identifyPayload = v2Identify(params: [:])
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        var windowNodes: [[String: Any]] = []

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()

            for (windowIndex, summary) in summaries.enumerated() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                let workspaceNodes = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }
                windowNodes.append(
                    v2TopWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodes
                    )
                )
            }
        }
        v2AttachTopApplicationProcess(to: &windowNodes)

        let processSnapshot = await withTaskGroup(
            of: CmuxTopProcessSnapshot.self,
            returning: CmuxTopProcessSnapshot.self
        ) { group in
            group.addTask(priority: .utility) {
                CmuxTopProcessSnapshot.capture(includeProcessDetails: includeProcesses)
            }
            return await group.next()!
        }
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        var annotatedWindows = windowNodes
        let totalPIDs = v2AnnotateTopWindows(
            &annotatedWindows,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: includeProcesses
        )
        let aggregates = processAggregates(from: processSnapshot, totalPIDs: totalPIDs)
        let memoryDiagnostic = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: annotatedWindows
        )

        return [
            "active": focused.isEmpty ? (NSNull() as Any) : focused,
            "caller": NSNull(),
            "sample": processSnapshot.samplePayload(),
            "totals": processSnapshot.summaryPayload(for: totalPIDs),
            "memory_diagnostic": memoryDiagnostic,
            "program_totals": aggregates.programs,
            "coding_agents": aggregates.codingAgents,
            "windows": annotatedWindows
        ]
    }

    private nonisolated func processAggregates(
        from processSnapshot: CmuxTopProcessSnapshot,
        totalPIDs: Set<Int>
    ) -> (programs: [[String: Any]], codingAgents: [[String: Any]]) {
        (
            programs: processSnapshot.programSummaryPayload(for: totalPIDs),
            codingAgents: processSnapshot.codingAgentSummaryPayload(for: totalPIDs)
        )
    }

    nonisolated func v2SystemTop(params: [String: Any]) -> V2CallResult {
        let base = v2MainSync {
            self.v2RefreshKnownRefs()
            return self.v2SystemTopBasePayload(params: params)
        }
        guard case .ok(let value) = base else { return base }
        guard var payload = value as? [String: Any],
              let includeProcesses = payload.removeValue(forKey: "include_processes") as? Bool,
              var windowNodes = payload.removeValue(forKey: "windows") as? [[String: Any]] else {
            return .err(code: "internal_error", message: "Invalid system.top payload", data: nil)
        }
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: includeProcesses)
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        let totalPIDs = v2AnnotateTopWindows(
            &windowNodes,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: includeProcesses
        )
        let aggregates = processAggregates(from: processSnapshot, totalPIDs: totalPIDs)
        let memoryDiagnostic = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windowNodes
        )

        payload["sample"] = processSnapshot.samplePayload()
        payload["totals"] = processSnapshot.summaryPayload(for: totalPIDs)
        payload["memory_diagnostic"] = memoryDiagnostic
        payload["program_totals"] = aggregates.programs
        payload["coding_agents"] = aggregates.codingAgents
        payload["windows"] = windowNodes
        return .ok(payload)
    }

    nonisolated func v2SystemMemory(params: [String: Any]) -> V2CallResult {
        var baseParams = params
        baseParams["include_processes"] = false
        let base = v2MainSync {
            self.v2RefreshKnownRefs()
            return self.v2SystemTopBasePayload(params: baseParams)
        }
        guard case .ok(let value) = base else { return base }
        guard var payload = value as? [String: Any],
              var windowNodes = payload.removeValue(forKey: "windows") as? [[String: Any]] else {
            return .err(code: "internal_error", message: "Invalid system.memory payload", data: nil)
        }
        func intParam(_ key: String) -> Int? {
            if let i = params[key] as? Int { return i }
            if let n = params[key] as? NSNumber {
                guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
                let value = n.doubleValue
                guard value.isFinite,
                      value.rounded(.towardZero) == value,
                      value >= Double(Int.min),
                      value <= Double(Int.max) else {
                    return nil
                }
                return n.intValue
            }
            if let s = params[key] as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      trimmed.range(of: #"^[+-]?\d+$"#, options: .regularExpression) != nil else {
                    return nil
                }
                return Int(trimmed)
            }
            return nil
        }
        var invalidLimitKey: String?
        func groupLimitParam(_ key: String) -> Int? {
            guard params[key] != nil else { return nil }
            guard let value = intParam(key), (1...100).contains(value) else {
                invalidLimitKey = key
                return nil
            }
            return value
        }
        let topGroupLimitValue = groupLimitParam("top_group_limit")
        if let invalidLimitKey {
            return .err(code: "invalid_params", message: "\(invalidLimitKey) must be an integer from 1 to 100", data: nil)
        }
        let groupLimitValue = groupLimitParam("group_limit")
        if let invalidLimitKey {
            return .err(code: "invalid_params", message: "\(invalidLimitKey) must be an integer from 1 to 100", data: nil)
        }
        let topGroupLimit = topGroupLimitValue ?? groupLimitValue ?? 12
        let processSnapshot = CmuxTopProcessSnapshot.captureCached(
            includeProcessDetails: true,
            maximumAge: 2
        )
        let browserPIDOccurrences = v2TopBrowserPIDOccurrences(in: windowNodes)
        _ = v2AnnotateTopWindows(
            &windowNodes,
            processSnapshot: processSnapshot,
            browserPIDOccurrences: browserPIDOccurrences,
            includeProcesses: false
        )
        payload["sample"] = processSnapshot.samplePayload()
        payload["memory_diagnostic"] = v2TopMemoryDiagnosticPayload(
            processSnapshot: processSnapshot,
            annotatedWindows: windowNodes,
            topGroupLimit: topGroupLimit
        )
        return .ok(payload)
    }

    private func v2SystemTopBasePayload(params: [String: Any]) -> V2CallResult {
        let workspaceFilter = v2UUID(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
        }
        if params["include_processes"] != nil, v2Bool(params, "include_processes") == nil { return .err(code: "invalid_params", message: "Missing or invalid include_processes", data: nil) }
        let includeProcesses = v2Bool(params, "include_processes") ?? false
        let routingResult = parseV2WindowRouting(params: params)
        if let error = routingResult.error { return error }
        guard let routing = routingResult.routing else {
            return .err(code: "internal_error", message: "Invalid window routing payload", data: nil)
        }

        var windowNodes: [[String: Any]] = []
        var workspaceFound = (workspaceFilter == nil)
        var windowFound = (routing.requestedWindowId == nil)

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = routing.requestedWindowId ?? routing.focusedWindowId ?? summaries.first?.windowId

            for (windowIndex, summary) in summaries.enumerated() {
                if let requestedWindowId = routing.requestedWindowId, summary.windowId != requestedWindowId {
                    continue
                }
                windowFound = true
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windowNodes = [
                        v2TopWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: [workspaceNode]
                        )
                    ]
                    workspaceFound = true
                    break
                }

                if !routing.includeAllWindows && summary.windowId != defaultWindowId {
                    continue
                }

                let workspaceNodesForWindow = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TopWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }

                windowNodes.append(
                    v2TopWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodesForWindow
                    )
                )
            }
        }

        v2AttachTopApplicationProcess(to: &windowNodes, workspaceFilter: workspaceFilter)

        if let requestedWindowId = routing.requestedWindowId, !windowFound {
            return v2WindowNotFoundResult(params: params, windowId: requestedWindowId)
        }
        if let workspaceFilter, !workspaceFound {
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: [
                    "workspace_id": workspaceFilter.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceFilter)
                ]
            )
        }

        return .ok([
            "active": routing.focused.isEmpty ? (NSNull() as Any) : routing.focused,
            "caller": routing.caller.isEmpty ? (NSNull() as Any) : routing.caller,
            "include_processes": includeProcesses,
            "windows": windowNodes
        ])
    }

    private func v2TopWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [[String: Any]]
    ) -> [String: Any] {
        return [
            "kind": "window",
            "id": summary.windowId.uuidString,
            "ref": v2Ref(kind: .window, uuid: summary.windowId),
            "index": index,
            "key": summary.isKeyWindow,
            "visible": summary.isVisible,
            "workspace_count": workspaceNodes.count,
            "selected_workspace_id": v2OrNull(summary.selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: summary.selectedWorkspaceId),
            "workspaces": workspaceNodes
        ]
    }

    private func v2TopWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> [String: Any] {
        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]

        let paneIds = workspace.bonsplitController.allPaneIds
        for paneId in paneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            for (tabIndex, tab) in tabs.enumerated() {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = tabIndex
                selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
            }
        }

        var surfacesByPane: [UUID: [[String: Any]]] = [:]
        let focusedSurfaceId = workspace.focusedPanelId
        for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
            let paneUUID = paneByPanelId[panel.id]
            let selectedInPane = selectedInPaneByPanelId[panel.id] ?? false

            var item: [String: Any] = [
                "kind": "surface",
                "id": panel.id.uuidString,
                "ref": v2Ref(kind: .surface, uuid: panel.id),
                "index": surfaceIndex,
                "type": panel.panelType.rawValue,
                "title": workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                "focused": panel.id == focusedSurfaceId,
                "selected": selectedInPane,
                "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id]),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                "tty": v2OrNull(workspace.surfaceTTYNames[panel.id]),
                "webviews": []
            ]

            if panel.panelType == .browser, let browserPanel = panel as? BrowserPanel {
                let webContentPID = CmuxWebContentProcessIdentifier.pid(for: browserPanel.webView)
                let url = browserPanel.currentURL?.absoluteString ?? ""
                let webViewLifecycle = browserPanel.webViewLifecycleTopPayload()
                item["url"] = url
                item["browser_web_content_pid"] = v2OrNull(webContentPID)
                item["browser_webview_lifecycle_state"] = browserPanel.webViewLifecycleState.rawValue
                item["webviews"] = [
                    [
                        "kind": "webview",
                        "id": "\(panel.id.uuidString):webview",
                        "ref": "\(v2Ref(kind: .surface, uuid: panel.id)):webview",
                        "index": 0,
                        "surface_id": panel.id.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: panel.id),
                        "title": browserPanel.displayTitle,
                        "url": url,
                        "pid": v2OrNull(webContentPID),
                        "lifecycle": webViewLifecycle
                    ] as [String: Any]
                ]
            } else {
                item["url"] = NSNull()
                item["browser_web_content_pid"] = NSNull()
            }
            if let paneUUID {
                surfacesByPane[paneUUID, default: []].append(item)
            }
        }

        for paneUUID in surfacesByPane.keys {
            surfacesByPane[paneUUID]?.sort {
                let lhs = ($0["index_in_pane"] as? Int) ?? ($0["index"] as? Int) ?? Int.max
                let rhs = ($1["index_in_pane"] as? Int) ?? ($1["index"] as? Int) ?? Int.max
                return lhs < rhs
            }
        }

        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let panes: [[String: Any]] = paneIds.enumerated().map { paneIndex, paneId in
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let surfaceUUIDs: [UUID] = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            let selectedSurfaceUUID = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }

            return [
                "kind": "pane",
                "id": paneId.id.uuidString,
                "ref": v2Ref(kind: .pane, uuid: paneId.id),
                "index": paneIndex,
                "focused": paneId == focusedPaneId,
                "surface_ids": surfaceUUIDs.map { $0.uuidString },
                "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                "surface_count": surfaceUUIDs.count,
                "surfaces": surfacesByPane[paneId.id] ?? []
            ]
        }

        return [
            "kind": "workspace",
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "index": index,
            "title": workspace.title,
            "description": v2OrNull(workspace.customDescription),
            "selected": selected,
            "pinned": workspace.isPinned,
            "panes": panes,
            "tags": v2TopTagNodes(for: workspace)
        ]
    }

    private func v2TopTagNodes(for workspace: Workspace) -> [[String: Any]] {
        var tags: [[String: Any]] = []
        var seenKeys = Set<String>()

        for (index, entry) in workspace.sidebarStatusEntriesInDisplayOrder().enumerated() {
            let pid = workspace.agentPIDs[entry.key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append([
                "kind": "tag",
                "id": v2TopTagIdentifier(workspaceId: workspace.id, key: entry.key),
                "ref": v2TopTagRef(workspaceId: workspace.id, key: entry.key),
                "index": index,
                "key": entry.key,
                "value": entry.value,
                "icon": v2OrNull(entry.icon),
                "color": v2OrNull(entry.color),
                "url": v2OrNull(entry.url?.absoluteString),
                "priority": entry.priority,
                "format": entry.format.rawValue,
                "visible": true,
                "pid": v2OrNull(pid)
            ])
            seenKeys.insert(entry.key)
        }

        for key in workspace.agentPIDs.keys.sorted() where !seenKeys.contains(key) {
            let pid = workspace.agentPIDs[key].flatMap { $0 > 0 ? Int($0) : nil }
            tags.append([
                "kind": "tag",
                "id": v2TopTagIdentifier(workspaceId: workspace.id, key: key),
                "ref": v2TopTagRef(workspaceId: workspace.id, key: key),
                "index": tags.count,
                "key": key,
                "value": "",
                "icon": NSNull(),
                "color": NSNull(),
                "url": NSNull(),
                "priority": 0,
                "format": "plain",
                "visible": false,
                "pid": v2OrNull(pid)
            ])
        }

        return tags
    }

    private func v2TreeWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [[String: Any]]
    ) -> [String: Any] {
        return [
            "id": summary.windowId.uuidString,
            "ref": v2Ref(kind: .window, uuid: summary.windowId),
            "index": index,
            "key": summary.isKeyWindow,
            "visible": summary.isVisible,
            "workspace_count": workspaceNodes.count,
            "selected_workspace_id": v2OrNull(summary.selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: summary.selectedWorkspaceId),
            "workspaces": workspaceNodes
        ]
    }

    private func v2TreeWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> [String: Any] {
        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]

        let paneIds = workspace.bonsplitController.allPaneIds
        for paneId in paneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            for (tabIndex, tab) in tabs.enumerated() {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = tabIndex
                selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
            }
        }

        var surfacesByPane: [UUID: [[String: Any]]] = [:]
        let focusedSurfaceId = workspace.focusedPanelId
        for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
            let paneUUID = paneByPanelId[panel.id]
            let selectedInPane = selectedInPaneByPanelId[panel.id] ?? false

            var item: [String: Any] = [
                "id": panel.id.uuidString,
                "ref": v2Ref(kind: .surface, uuid: panel.id),
                "index": surfaceIndex,
                "type": panel.panelType.rawValue,
                "title": workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                "focused": panel.id == focusedSurfaceId,
                "selected": selectedInPane,
                "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id]),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                "tty": v2OrNull(workspace.surfaceTTYNames[panel.id])
            ]

            if panel.panelType == .browser, let browserPanel = panel as? BrowserPanel {
                item["url"] = browserPanel.currentURL?.absoluteString ?? ""
            } else {
                item["url"] = NSNull()
            }
            if let paneUUID {
                surfacesByPane[paneUUID, default: []].append(item)
            }
        }

        for paneUUID in surfacesByPane.keys {
            surfacesByPane[paneUUID]?.sort {
                let lhs = ($0["index_in_pane"] as? Int) ?? ($0["index"] as? Int) ?? Int.max
                let rhs = ($1["index_in_pane"] as? Int) ?? ($1["index"] as? Int) ?? Int.max
                return lhs < rhs
            }
        }

        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let panes: [[String: Any]] = paneIds.enumerated().map { paneIndex, paneId in
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let surfaceUUIDs: [UUID] = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            let selectedSurfaceUUID = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }

            return [
                "id": paneId.id.uuidString,
                "ref": v2Ref(kind: .pane, uuid: paneId.id),
                "index": paneIndex,
                "focused": paneId == focusedPaneId,
                "surface_ids": surfaceUUIDs.map { $0.uuidString },
                "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                "surface_count": surfaceUUIDs.count,
                "surfaces": surfacesByPane[paneId.id] ?? []
            ]
        }

        return [
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "index": index,
            "title": workspace.title,
            "description": v2OrNull(workspace.customDescription),
            "selected": selected,
            "pinned": workspace.isPinned,
            "panes": panes
        ]
    }

    // MARK: - V2 Helpers (encoding + result plumbing)
    // MARK: - V2 Helpers (encoding + result plumbing)

}
