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


// MARK: - V2 debug file-drop and sidebar-drag simulation
extension TerminalController {
#if DEBUG
    func v2DebugSimulateTerminalFileDrop(params: [String: Any]) -> V2CallResult {
        guard let tabManager else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        guard let rawPaths = params["paths"] as? [String] else {
            return .err(code: "invalid_params", message: "Missing paths", data: nil)
        }
        let paths = rawPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return .err(code: "invalid_params", message: "paths must not be empty", data: nil)
        }

        let route = (v2String(params, "route") ?? "text_destination")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        enum TerminalFileDropSimulationRoute {
            case terminal
            case textDestination
        }
        enum TerminalFileDropSimulationPayload {
            case fileURLs
            case imageData
        }
        let simulationRoute: TerminalFileDropSimulationRoute
        switch route {
        case "terminal", "direct":
            simulationRoute = .terminal
        case "text", "text_destination", "pane_text":
            simulationRoute = .textDestination
        default:
            return .err(code: "invalid_params", message: "Unknown route", data: [
                "route": route
            ])
        }
        let payload = (v2String(params, "payload") ?? "file_urls")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let simulationPayload: TerminalFileDropSimulationPayload
        switch payload {
        case "file", "files", "file_url", "file_urls":
            simulationPayload = .fileURLs
        case "image", "image_data", "images":
            simulationPayload = .imageData
        default:
            return .err(code: "invalid_params", message: "Unknown payload", data: [
                "payload": payload
            ])
        }

        var result: V2CallResult = .err(code: "not_found", message: "Terminal surface not found", data: [
            "surface_id": surfaceId
        ])
        v2MainSync {
            guard let panel = resolveTerminalPanel(from: surfaceId, tabManager: tabManager) else {
                return
            }

            switch simulationRoute {
            case .terminal:
                let handled = panel.hostedView.debugSimulateFileDrop(
                    paths: paths,
                    asImageData: simulationPayload == .imageData
                )
                result = handled
                    ? .ok(["handled": true, "route": "terminal", "payload": payload])
                    : .err(code: "internal_error", message: "Terminal drop simulation failed", data: nil)
            case .textDestination:
                guard simulationPayload == .fileURLs else {
                    result = .err(code: "invalid_params", message: "Image data payload requires terminal route", data: [
                        "route": route,
                        "payload": payload
                    ])
                    return
                }
                guard let workspace = tabManager.tabs.first(where: { $0.id == panel.workspaceId }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: [
                        "workspace_id": panel.workspaceId.uuidString
                    ])
                    return
                }
                let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
                let handled = FileDropTextDropController.performTerminalFileDrop(
                    workspace: workspace,
                    panelId: panel.id,
                    hostedView: panel.hostedView,
                    urls: urls,
                    window: panel.surface.uiWindow
                )
                result = handled
                    ? .ok(["handled": true, "route": "text_destination", "payload": payload])
                    : .err(code: "internal_error", message: "Text destination drop simulation failed", data: nil)
            }
        }
        return result
    }

    /// Drives `SidebarDragState.draggedTabId` and `dropIndicator` mutations
    /// across N steps from a starting workspace toward a target neighbor.
    /// External profilers (e.g. the `profile-pr` skill driving `xctrace`)
    /// invoke this between `xctrace record --launch` and `xctrace stop` to
    /// generate a deterministic 60Hz-style drag load without HID synthesis.
    /// Never commits the reorder; calls back with the synthesized step path.
    ///
    /// Runs on the socket worker (see `ControlCommandExecutionPolicy`) so the
    /// inter-tick `Thread.sleep` doesn't block the main actor — every
    /// dragState mutation hops to main via `v2MainSync`.
    nonisolated func v2DebugSidebarSimulateDrag(params: [String: Any]) -> V2CallResult {
        // Dispatched on the socket worker (see ControlCommandExecutionPolicy) so the
        // inter-tick Thread.sleep doesn't block the main actor. All parameter
        // resolution (including workspace:N -> UUID ref-resolution) and the
        // SidebarDragState mutations hop to main via v2MainSync.

        enum PlanResult {
            case ok(
                windowId: UUID,
                fromTabId: UUID,
                toTabId: UUID,
                tabIds: [UUID],
                fromIndex: Int,
                toIndex: Int,
                durationMs: Int,
                requestedSteps: Int?
            )
            case err(code: String, message: String, data: [String: Any]?)
        }

        let planResult: PlanResult = v2MainSync {
            guard let windowId = v2UUID(params, "window_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
            }
            // Scope to the requested window. self.tabManager is the controller's
            // primary tabManager; in multi-window runs that's the wrong list for
            // a window_id other than the primary.
            guard let windowTabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                return .err(
                    code: "not_found",
                    message: "No TabManager for window_id",
                    data: ["window_id": windowId.uuidString]
                )
            }
            guard let fromTabId = v2UUID(params, "from_tab_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid from_tab_id", data: nil)
            }
            guard let toTabId = v2UUID(params, "to_tab_id") else {
                return .err(code: "invalid_params", message: "Missing or invalid to_tab_id", data: nil)
            }
            let durationMs: Int
            if v2HasNonNullParam(params, "duration_ms") {
                guard let value = v2Int(params, "duration_ms"), value > 0 else {
                    return .err(code: "invalid_params", message: "duration_ms must be a positive integer", data: nil)
                }
                durationMs = value
            } else {
                durationMs = 1000
            }
            let requestedSteps: Int?
            if v2HasNonNullParam(params, "steps") {
                guard let value = v2Int(params, "steps"), value > 0 else {
                    return .err(code: "invalid_params", message: "steps must be a positive integer", data: nil)
                }
                requestedSteps = value
            } else {
                requestedSteps = nil
            }
            guard SidebarDragStateRegistry.state(forWindowId: windowId) != nil else {
                return .err(
                    code: "not_found",
                    message: "No mounted sidebar for window_id",
                    data: ["window_id": windowId.uuidString]
                )
            }
            let tabIds = windowTabManager.tabs.map(\.id)
            guard let fromIndex = tabIds.firstIndex(of: fromTabId) else {
                return .err(
                    code: "not_found",
                    message: "from_tab_id not in window's workspace list",
                    data: ["from_tab_id": fromTabId.uuidString]
                )
            }
            guard let toIndex = tabIds.firstIndex(of: toTabId) else {
                return .err(
                    code: "not_found",
                    message: "to_tab_id not in window's workspace list",
                    data: ["to_tab_id": toTabId.uuidString]
                )
            }
            guard fromIndex != toIndex else {
                return .err(code: "invalid_params", message: "from_tab_id and to_tab_id must differ", data: nil)
            }
            return .ok(
                windowId: windowId,
                fromTabId: fromTabId,
                toTabId: toTabId,
                tabIds: tabIds,
                fromIndex: fromIndex,
                toIndex: toIndex,
                durationMs: durationMs,
                requestedSteps: requestedSteps
            )
        }

        let windowId: UUID
        let fromTabId: UUID
        let toTabId: UUID
        let tabIds: [UUID]
        let fromIndex: Int
        let toIndex: Int
        let durationMs: Int
        let requestedSteps: Int?
        switch planResult {
        case let .err(code, message, data):
            return .err(code: code, message: message, data: data)
        case let .ok(w, f, t, ids, fi, ti, dur, steps):
            windowId = w; fromTabId = f; toTabId = t; tabIds = ids
            fromIndex = fi; toIndex = ti; durationMs = dur; requestedSteps = steps
        }

        let stride = fromIndex < toIndex ? 1 : -1
        let pathIndices = Swift.stride(from: fromIndex + stride, through: toIndex, by: stride).map { $0 }
        guard !pathIndices.isEmpty else {
            return .err(code: "invalid_params", message: "Empty drag path", data: nil)
        }
        // Allow requestedSteps > pathIndices.count: profiling at high tick
        // rates (e.g. 60Hz over a short row span) is a documented use case.
        // The resampling formula picks the same indicator value multiple
        // times in that regime, which is exactly the SwiftUI invalidation
        // load the skill measures.
        let steps = max(1, requestedSteps ?? pathIndices.count)
        // Resampler closure: maps step number (0..<steps) -> path index.
        // Not pre-materialized; computed inline in the simulation loop so
        // arbitrarily large --steps (e.g. 60Hz over hours) doesn't allocate
        // a giant [Int] up front.
        let pathCount = pathIndices.count
        let stepDivisor = Double(max(1, steps - 1))
        let resolveStepIndex: (Int) -> Int = { stepNumber in
            let position = Int(round(Double(stepNumber) * Double(pathCount - 1) / stepDivisor))
            return pathIndices[max(0, min(pathCount - 1, position))]
        }
        let stepIntervalMs = max(1, durationMs / steps)
        let edge: SidebarDropEdge = fromIndex < toIndex ? .bottom : .top
        // Cap the response payload's path array so very large --steps don't
        // serialize a giant JSON UUID list. The simulation still runs every
        // requested step; the response is just informational.
        let pathSampleLimit = 64

        // Start the drag. If the sidebar has already unregistered, fail loud
        // instead of silently sleeping through a no-op simulation.
        let startedOK: Bool = v2MainSync {
            guard let dragState = SidebarDragStateRegistry.state(forWindowId: windowId) else { return false }
            // Mark the drag as simulator-driven so VerticalTabsSidebar skips
            // starting SidebarDragFailsafeMonitor — it would otherwise post
            // mouse_up_failsafe immediately because no real mouse is pressed.
            dragState.isSimulated = true
            dragState.beginDragging(tabId: fromTabId)
            return true
        }
        guard startedOK else {
            return .err(
                code: "not_found",
                message: "Sidebar unregistered before simulation could start",
                data: ["window_id": windowId.uuidString]
            )
        }

        var aborted = false
        var pathSample: [String] = []
        pathSample.reserveCapacity(min(steps, pathSampleLimit))
        for stepNumber in 0..<steps {
            let tabIndex = resolveStepIndex(stepNumber)
            let targetTabId = tabIds[tabIndex]
            if pathSample.count < pathSampleLimit {
                pathSample.append(targetTabId.uuidString)
            }
            let tickOK: Bool = v2MainSync {
                guard let dragState = SidebarDragStateRegistry.state(forWindowId: windowId) else { return false }
                dragState.setDropIndicator(SidebarDropIndicator(tabId: targetTabId, edge: edge))
                return true
            }
            if !tickOK {
                aborted = true
                break
            }
            if stepIntervalMs > 0 {
                Thread.sleep(forTimeInterval: TimeInterval(stepIntervalMs) / 1000.0)
            }
        }

        v2MainSync {
            guard let dragState = SidebarDragStateRegistry.state(forWindowId: windowId) else { return }
            dragState.clearDrag()
            dragState.isSimulated = false
        }

        if aborted {
            return .err(
                code: "aborted",
                message: "Sidebar unregistered mid-simulation",
                data: ["window_id": windowId.uuidString]
            )
        }

        var payload: [String: Any] = [
            "window_id": windowId.uuidString,
            "from_tab_id": fromTabId.uuidString,
            "to_tab_id": toTabId.uuidString,
            "steps": steps,
            "step_interval_ms": stepIntervalMs,
            "duration_ms": stepIntervalMs * steps,
            "edge": edge == .top ? "top" : "bottom",
            "path": pathSample
        ]
        if steps > pathSampleLimit {
            payload["path_truncated"] = true
            payload["path_full_size"] = steps
        }
        return .ok(payload)
    }
#endif
}
