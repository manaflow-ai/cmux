import AppKit
import CmuxControlSocket
import Foundation

/// App-side wiring for the worker-lane `system.top` / `system.memory` control
/// commands.
///
/// The command dispatch lives in CmuxControlSocket's ``ControlSystemTopWorker``;
/// this file supplies the live-state seam (``ControlSystemTopReading``) the
/// worker reads through, plus the synchronous worker-lane entry point that drives
/// it. The full command bodies (the `v2SystemTopBasePayload` live-graph walk +
/// window routing, the `CmuxTopProcessSnapshot` sampling, the `[String: Any]`
/// annotation pipeline, and the final payload assembly) live here because they
/// reach `AppDelegate` and an app-target process snapshot, which CmuxControlSocket
/// must not import.
///
/// ## Why the seam, not a direct call
///
/// ``ControlSystemTopWorker`` is in a package that must not import `AppKit`, the
/// app target's `AppDelegate` / `TabManager` / `Workspace` graph, or the
/// app-target `CmuxTopProcessSnapshot`. ``ControlSystemTopReading`` inverts that:
/// the package owns the protocol and the dispatch; ``TerminalControllerSystemTopReading``
/// conforms it over a `weak` ``TerminalController``, forwarding to the
/// controller's co-located resolvers (`controlResolveSystemTop` /
/// `controlResolveSystemMemory`). Those run on the calling socket-worker thread
/// (the blocking snapshot sampling and annotation stay off the main actor exactly
/// as the legacy `nonisolated` `v2SystemTop` / `v2SystemMemory` bodies did),
/// hopping to main only inside the `v2MainSync` base-payload block.
extension TerminalController {
    /// Drives the package ``ControlSystemTopWorker`` for one decoded `system.top`
    /// / `system.memory` request from the synchronous socket-worker lane. The
    /// worker is synchronous (the snapshot sampling and annotation block the
    /// worker thread, as the legacy bodies did), so no worker-thread→async bridge
    /// is needed. The worker only ever returns `nil` for non-`system.top` /
    /// non-`system.memory` methods, which the dispatcher never routes here, so a
    /// `nil` result reports the same encode-failure response the legacy plumbing
    /// produced for an impossible payload.
    nonisolated func runSystemTopWorker(_ request: ControlRequest) -> String {
        guard let worker = controlSystemTopWorker,
              let result = worker.handle(request) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }

    /// Resolves a `system.top` request, byte-faithful to the former `v2SystemTop`:
    /// builds the base payload on the main actor (`v2RefreshKnownRefs` +
    /// `controlSystemTopBasePayload`), samples the process snapshot on the worker
    /// thread, runs the `[String: Any]` annotation pipeline, and assembles the
    /// final dictionary, bridged to the typed ``ControlCallResult``.
    nonisolated func controlResolveSystemTop(params: [String: JSONValue]) -> ControlCallResult {
        Self.controlCallResult(from: v2SystemTop(params: params.foundationParams))
    }

    /// Resolves a `system.memory` request, byte-faithful to the former
    /// `v2SystemMemory`.
    nonisolated func controlResolveSystemMemory(params: [String: JSONValue]) -> ControlCallResult {
        Self.controlCallResult(from: v2SystemMemory(params: params.foundationParams))
    }

    /// Bridges a legacy `V2CallResult` to the typed ``ControlCallResult`` at the
    /// seam. The `system.top` / `system.memory` payloads are provably JSON-safe
    /// (strings, bools, ints, doubles, arrays, nested dictionaries, and
    /// `NSNull`), so the `JSONValue(foundationObject:)` bridge never falls back;
    /// the unencodable-payload `.err` branch is defensive only.
    private static func controlCallResult(from result: V2CallResult) -> ControlCallResult {
        switch result {
        case .ok(let payload):
            guard let value = JSONValue(foundationObject: payload) else {
                return .err(code: "internal_error", message: "Invalid system payload", data: nil)
            }
            return .ok(value)
        case .err(let code, let message, let data):
            return .err(code: code, message: message, data: data.flatMap { JSONValue(foundationObject: $0) })
        }
    }

    // MARK: - system.top / system.memory command bodies (lifted from TerminalController)

    private nonisolated func v2SystemTop(params: [String: Any]) -> V2CallResult {
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

    private nonisolated func v2SystemMemory(params: [String: Any]) -> V2CallResult {
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

    /// The resolved window-routing inputs for `system.top` / `system.memory`
    /// (the former `TerminalController.V2WindowRouting`). Carried only between
    /// `parseV2WindowRouting` and `v2SystemTopBasePayload`.
    private struct V2WindowRouting {
        let includeAllWindows: Bool
        let requestedWindowId: UUID?
        let focused: [String: Any]
        let caller: [String: Any]
        let focusedWindowId: UUID?
    }

    /// The `window_id` selector echo for an invalid/not-found window error
    /// payload (the former `v2WindowSelectorDetails`).
    private func v2WindowSelectorDetails(params: [String: Any]) -> [String: Any]? {
        guard let rawWindowId = params["window_id"] else { return nil }
        if let string = rawWindowId as? String {
            return ["window_id": string]
        }
        return ["window_id": String(describing: rawWindowId)]
    }

    /// Parses + validates the `all_windows` / `window_id` selectors and resolves
    /// the focused/caller routing context (the former `parseV2WindowRouting`),
    /// byte-faithful to the legacy validation order and messages.
    private func parseV2WindowRouting(params: [String: Any]) -> (routing: V2WindowRouting?, error: V2CallResult?) {
        if params["all_windows"] != nil, v2Bool(params, "all_windows") == nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Invalid all_windows. Pass true or false, or omit it. Use --window <id|ref|index> to target one window or --all-windows to target all windows.",
                    data: nil
                )
            )
        }

        let includeAllWindows = v2Bool(params, "all_windows") ?? false
        let requestedWindowId = v2UUID(params, "window_id")
        if params["window_id"] != nil && requestedWindowId == nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Invalid window selector. Use --window <id|ref|index> to target one window, or run `cmux list-windows` to see available windows and retry.",
                    data: v2WindowSelectorDetails(params: params)
                )
            )
        }
        if includeAllWindows, requestedWindowId != nil {
            return (
                nil,
                .err(
                    code: "invalid_params",
                    message: "Choose either --window <id|ref|index> or --all-windows, not both. Run `cmux list-windows` to see available windows and retry.",
                    data: v2WindowSelectorDetails(params: params)
                )
            )
        }

        var identifyParams: [String: Any] = [:]
        if let caller = params["caller"] as? [String: Any], !caller.isEmpty {
            identifyParams["caller"] = caller
        }
        if let requestedWindowId {
            identifyParams["window_id"] = requestedWindowId.uuidString
        }
        let identifyPayload = v2Identify(params: identifyParams)
        let focused = identifyPayload["focused"] as? [String: Any] ?? [:]
        let caller = identifyPayload["caller"] as? [String: Any] ?? [:]
        let focusedWindowId = v2UUIDAny(focused["window_id"]) ?? v2UUIDAny(focused["window_ref"])
        return (
            V2WindowRouting(
                includeAllWindows: includeAllWindows,
                requestedWindowId: requestedWindowId,
                focused: focused,
                caller: caller,
                focusedWindowId: focusedWindowId
            ),
            nil
        )
    }

    /// The window-not-found error for an explicit `window_id` that matched no
    /// live window (the former `v2WindowNotFoundResult`).
    private func v2WindowNotFoundResult(params: [String: Any], windowId: UUID) -> V2CallResult {
        .err(
            code: "not_found",
            message: "Window not found. Run `cmux list-windows` to see available windows, then retry with --window <id|ref|index>.",
            data: v2WindowSelectorDetails(params: params) ?? ["window_id": windowId.uuidString]
        )
    }

    /// Builds the `system.top` window payload dictionary, byte-faithful to the
    /// former `v2TopWindowNode`: assembles a typed ``ControlSystemTopWindowNode``
    /// from live `AppDelegate.MainWindowSummary` state plus the already-built
    /// typed workspace nodes, shapes it through the coordinator
    /// (``ControlCommandCoordinator/systemTopWindowPayload(_:)``), then bridges
    /// the JSON value back to a Foundation dictionary for the worker-lane
    /// annotation pipeline. The window-node dictionary shaping (the `kind`
    /// marker, the minted refs, the flags, and the nested workspaces array) lives
    /// in the package now; only the live `AppDelegate` reads stay here.
    func v2TopWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [ControlSystemTopWorkspaceNode]
    ) -> [String: Any] {
        let node = ControlSystemTopWindowNode(
            windowID: summary.windowId,
            index: index,
            isKeyWindow: summary.isKeyWindow,
            isVisible: summary.isVisible,
            selectedWorkspaceID: summary.selectedWorkspaceId,
            workspaces: workspaceNodes
        )
        let payload = controlCommandCoordinator.systemTopWindowPayload(node)
        // The shaped payload is always a JSON object; `.foundationObject` of an
        // object is a `[String: Any]`, so this cast never fails for valid input.
        return (payload.foundationObject as? [String: Any]) ?? [:]
    }
}

/// Conforms ``ControlSystemTopReading`` over a `weak` ``TerminalController``.
///
/// `@unchecked Sendable` (not `@MainActor`): ``resolveTop(params:)`` /
/// ``resolveMemory(params:)`` must run on the socket-worker thread so the
/// blocking snapshot sampling and annotation never hold the main actor, matching
/// the legacy `nonisolated` `v2SystemTop` / `v2SystemMemory` bodies. The only
/// stored member is a `weak` reference to the app-lifetime `TerminalController`
/// singleton; the controller's resolvers are `nonisolated` and perform their own
/// `v2MainSync` hop internally, so no isolation is required on the conformer. The
/// `weak` reference is read on the worker thread, which is safe for a singleton
/// whose lifetime spans every connection.
final class TerminalControllerSystemTopReading: ControlSystemTopReading, @unchecked Sendable {
    private weak var owner: TerminalController?

    /// Creates the conformer.
    /// - Parameter owner: The controller whose live system state backs the seam.
    init(owner: TerminalController) {
        self.owner = owner
    }

    func resolveTop(params: [String: JSONValue]) -> ControlCallResult {
        guard let owner else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return owner.controlResolveSystemTop(params: params)
    }

    func resolveMemory(params: [String: JSONValue]) -> ControlCallResult {
        guard let owner else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        return owner.controlResolveSystemMemory(params: params)
    }
}

private extension [String: JSONValue] {
    /// Bridges the typed worker-lane params to the legacy `[String: Any]` the
    /// lifted `v2SystemTop` / `v2SystemMemory` / `v2SystemTopBasePayload` bodies
    /// consume. `JSONValue.foundationObject` of an object is a `[String: Any]`,
    /// matching the Foundation params the legacy dispatch passed verbatim.
    var foundationParams: [String: Any] {
        mapValues { $0.foundationObject }
    }
}
