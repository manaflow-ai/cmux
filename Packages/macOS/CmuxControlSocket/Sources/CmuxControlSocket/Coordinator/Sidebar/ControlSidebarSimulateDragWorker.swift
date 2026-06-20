internal import Foundation

/// The worker-lane RPC handler for the `#if DEBUG` `debug.sidebar.simulate_drag`
/// control command, lifted byte-faithfully from
/// `TerminalController.v2DebugSidebarSimulateDrag`.
///
/// Drives `SidebarDragState.draggedTabId` / `dropIndicator` mutations across N
/// steps from a starting workspace toward a target neighbor so external profilers
/// (the `profile-pr` skill driving `xctrace`) can generate a deterministic
/// 60Hz-style drag load without HID synthesis. It never commits the reorder and
/// replies with the synthesized step path.
///
/// The worker owns the off-main compute: the path-index stride, the inline
/// resampler that maps step number → path index (never pre-materialized so a huge
/// `--steps` does not allocate), the per-tick interval, the inter-tick
/// `Thread.sleep`, the capped path-sample collection, and the reply payload. Every
/// piece of live state (param resolution, the `beginDragging` / `setDropIndicator`
/// / `clearDrag` mutations) is reached through the ``ControlSidebarSimulateDragReading``
/// seam, each call hopping to the main actor inside the conformer exactly as the
/// legacy `v2MainSync` blocks did.
///
/// ## Isolation
///
/// `Sendable` and `async`, NOT `@MainActor`: this command runs on the nonisolated
/// socket-worker lane (`runsOnSocketWorker`) so its inter-tick `Thread.sleep` does
/// not block the main actor. The `async` `handle` runs on the worker thread the
/// caller bridges in; the seam members hop to main internally. The wire payloads
/// are byte-identical to the legacy ones.
#if DEBUG
public struct ControlSidebarSimulateDragWorker: Sendable {
    /// The live sidebar/drag seam. Injected at construction.
    private let reading: any ControlSidebarSimulateDragReading

    /// Creates a worker.
    ///
    /// - Parameter reading: The sidebar-drag seam to read/drive.
    public init(reading: any ControlSidebarSimulateDragReading) {
        self.reading = reading
    }

    /// Runs one decoded request if it is `debug.sidebar.simulate_drag`, returning
    /// the typed result; returns `nil` for any other method so the caller can fall
    /// through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not the owned method.
    public func handle(_ request: ControlRequest) -> ControlCallResult? {
        guard request.method == "debug.sidebar.simulate_drag" else { return nil }
        return simulateDrag(request.params)
    }

    /// `debug.sidebar.simulate_drag` — the full simulation body.
    private func simulateDrag(_ params: [String: JSONValue]) -> ControlCallResult {
        // The plan step (param resolution + validation) hops to main inside the
        // seam, exactly like the legacy plan `v2MainSync` block.
        let plan: ControlSidebarSimulateDragPlan
        switch reading.plan(params: params) {
        case .error(let code, let message, let data):
            return .err(code: code, message: message, data: data)
        case .plan(let resolved):
            plan = resolved
        }

        let windowId = plan.windowId
        let fromTabId = plan.fromTabId
        let toTabId = plan.toTabId
        let tabIds = plan.tabIds
        let fromIndex = plan.fromIndex
        let toIndex = plan.toIndex
        let durationMs = plan.durationMs
        let requestedSteps = plan.requestedSteps

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
        let edgeIsBottom = fromIndex < toIndex
        // Cap the response payload's path array so very large --steps don't
        // serialize a giant JSON UUID list. The simulation still runs every
        // requested step; the response is just informational.
        let pathSampleLimit = 64

        // Start the drag. If the sidebar has already unregistered, fail loud
        // instead of silently sleeping through a no-op simulation.
        let startedOK = reading.begin(windowId: windowId, fromTabId: fromTabId)
        guard startedOK else {
            return .err(
                code: "not_found",
                message: "Sidebar unregistered before simulation could start",
                data: .object(["window_id": .string(windowId.uuidString)])
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
            let tickOK = reading.tick(windowId: windowId, tabId: targetTabId, edgeIsBottom: edgeIsBottom)
            if !tickOK {
                aborted = true
                break
            }
            if stepIntervalMs > 0 {
                Thread.sleep(forTimeInterval: TimeInterval(stepIntervalMs) / 1000.0)
            }
        }

        reading.clear(windowId: windowId)

        if aborted {
            return .err(
                code: "aborted",
                message: "Sidebar unregistered mid-simulation",
                data: .object(["window_id": .string(windowId.uuidString)])
            )
        }

        var payload: [String: JSONValue] = [
            "window_id": .string(windowId.uuidString),
            "from_tab_id": .string(fromTabId.uuidString),
            "to_tab_id": .string(toTabId.uuidString),
            "steps": .int(Int64(steps)),
            "step_interval_ms": .int(Int64(stepIntervalMs)),
            "duration_ms": .int(Int64(stepIntervalMs * steps)),
            "edge": .string(edgeIsBottom ? "bottom" : "top"),
            "path": .array(pathSample.map { .string($0) }),
        ]
        if steps > pathSampleLimit {
            payload["path_truncated"] = .bool(true)
            payload["path_full_size"] = .int(Int64(steps))
        }
        return .ok(.object(payload))
    }
}
#endif
