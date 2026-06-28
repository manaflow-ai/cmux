import CmuxControlSocket
import Foundation

/// The `system.top` / `system.memory` / task-manager command bodies: the
/// payload-builder layer that drives the live-state walk (``AppDelegate/shared``
/// main-window summaries, each window's ``TabManager`` tabs / `selectedTabId`),
/// captures a ``CmuxTopProcessSnapshot``, annotates the window tree with process
/// usage, and aggregates per-program / coding-agent totals into the final
/// `[String: Any]` payload.
///
/// `taskManagerTopPayload` feeds the Task Manager window
/// (``TaskManagerWindowController``); `v2SystemTop` / `v2SystemMemory` are the
/// socket-dispatch witnesses (``TerminalController`` `system.top` /
/// `system.memory`). All node minting flows through the still-shared
/// `systemTopWorkspaceNode` / `v2TopWindowNode` builders in
/// `TerminalController+ControlSystemTopContext.swift`; the identify and
/// window-routing parse now live in the coordinator
/// (``ControlCommandCoordinator/identify(params:)`` /
/// ``ControlCommandCoordinator/systemWindowRouting(_:)`` /
/// ``ControlCommandCoordinator/systemWindowNotFound(_:windowID:)``), which this
/// worker-lane orchestration drives across the Foundation boundary.
extension TerminalController {

    func taskManagerTopPayload(includeProcesses: Bool) async throws -> [String: Any] {
        v2RefreshKnownRefs()

        let identifyPayload = controlCommandCoordinator.identify(params: [:]).foundationObject as? [String: Any] ?? [:]
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        var windowNodes: [[String: Any]] = []

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()

            for (windowIndex, summary) in summaries.enumerated() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
                let workspaceNodes = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    systemTopWorkspaceNode(
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
        // The former inline `intParam` closure was a byte-equivalent twin of the
        // shared `v2StrictIntAny` strict-integer parser (non-boolean integral
        // number truncated toward zero with range/finite guards, or a decimal
        // string), so the group-limit validation reuses the single shared helper
        // rather than carrying a duplicate parser in the god dispatch path.
        var invalidLimitKey: String?
        func groupLimitParam(_ key: String) -> Int? {
            guard params[key] != nil else { return nil }
            guard let value = v2StrictIntAny(params[key]), (1...100).contains(value) else {
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

        // The window-routing parse (selector validation + identify) lives in the
        // coordinator's `systemWindowRouting`, the single typed twin shared with
        // `system.tree`. Convert the Foundation params, drive it, and bridge the
        // `focused` / `caller` JSON objects back to Foundation for this payload.
        let jsonParams = v2JSONObjectParams(params)
        let routing: ControlCommandCoordinator.SystemWindowRouting
        switch controlCommandCoordinator.systemWindowRouting(jsonParams) {
        case .invalid(let error):
            return v2BridgeControlCallResult(error)
        case .routed(let routed):
            routing = routed
        }
        let focusedFoundation = routing.focused.mapValues(\.foundationObject)
        let callerFoundation = routing.caller.mapValues(\.foundationObject)

        var windowNodes: [[String: Any]] = []
        var workspaceFound = (workspaceFilter == nil)
        var windowFound = (routing.requestedWindowID == nil)

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = routing.requestedWindowID ?? routing.focusedWindowID ?? summaries.first?.windowId

            for (windowIndex, summary) in summaries.enumerated() {
                if let requestedWindowId = routing.requestedWindowID, summary.windowId != requestedWindowId {
                    continue
                }
                windowFound = true
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = systemTopWorkspaceNode(
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
                    systemTopWorkspaceNode(
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

        if let requestedWindowId = routing.requestedWindowID, !windowFound {
            return v2BridgeControlCallResult(
                controlCommandCoordinator.systemWindowNotFound(jsonParams, windowID: requestedWindowId)
            )
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
            "active": focusedFoundation.isEmpty ? (NSNull() as Any) : focusedFoundation,
            "caller": callerFoundation.isEmpty ? (NSNull() as Any) : callerFoundation,
            "include_processes": includeProcesses,
            "windows": windowNodes
        ])
    }

    /// Converts Foundation socket params to the coordinator's `JSONValue`
    /// params. The wire params are always a valid JSON object, so the whole-dict
    /// bridge succeeds; an unexpected non-JSON value degrades to an empty object
    /// (the routing reads only `all_windows` / `window_id` / `caller`, which are
    /// always JSON-convertible).
    private nonisolated func v2JSONObjectParams(_ params: [String: Any]) -> [String: JSONValue] {
        guard case .object(let object)? = JSONValue(foundationObject: params) else { return [:] }
        return object
    }

    /// Bridges a coordinator `ControlCallResult` back to the worker lane's
    /// Foundation-shaped `V2CallResult` (the inverse of the conformance bridges),
    /// folding the typed `JSONValue` payload/data into Foundation objects.
    private nonisolated func v2BridgeControlCallResult(_ result: ControlCallResult) -> V2CallResult {
        switch result {
        case .ok(let payload):
            return .ok(payload.foundationObject)
        case .err(let code, let message, let data):
            return .err(code: code, message: message, data: data?.foundationObject)
        }
    }
}
