#if DEBUG
import CmuxControlSocket
import CmuxFoundation
import CmuxSidebar
import Foundation

/// App-side wiring for the worker-lane `debug.sidebar.simulate_drag` control
/// command.
///
/// The simulation body lives in CmuxControlSocket's
/// ``ControlSidebarSimulateDragWorker``; this file supplies the live-state seam
/// (``ControlSidebarSimulateDragReading``) the worker drives through, plus the one
/// worker-thread→async bridge that lets the synchronous `nonisolated`
/// socket-worker lane run the worker.
///
/// ## Why the seam, not a direct call
///
/// `ControlSidebarSimulateDragWorker` is in a package that must not import the
/// app target or `CmuxSidebar` (`AppDelegate`, the per-window `TabManager`, and
/// `SidebarDragState`). ``ControlSidebarSimulateDragReading`` inverts that: the
/// package owns the protocol and the off-main orchestration (resampling, the
/// inter-tick `Thread.sleep` loop, the reply payload), and
/// ``TerminalControllerSidebarSimulateDragReading`` performs each main-actor side
/// effect (param resolution, `beginDragging` / `setDropIndicator` / `clearDrag`),
/// each hop matching the legacy `v2DebugSidebarSimulateDrag` `v2MainSync` blocks.
extension TerminalController {
    /// Drives the package ``ControlSidebarSimulateDragWorker`` for one decoded
    /// `debug.sidebar.simulate_drag` request from the synchronous socket-worker
    /// lane. The worker is synchronous (its only suspension-free blocking is the
    /// inter-tick `Thread.sleep`, which must stay on the worker thread, never the
    /// cooperative pool), so it runs inline here with no async bridge. The worker
    /// only returns `nil` for a non-`debug.sidebar.simulate_drag` method, which the
    /// dispatcher never routes here, so a `nil` reports the same encode-failure
    /// response the legacy plumbing produced for an impossible payload.
    nonisolated func runSidebarSimulateDragWorker(_ request: ControlRequest) -> String {
        guard let result = controlSidebarSimulateDragWorker?.handle(request) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }
}

/// Conforms ``ControlSidebarSimulateDragReading`` over a `weak`
/// ``TerminalController``.
///
/// Every member runs one main-actor hop through the controller's `v2MainSync`
/// (the legacy body's `v2MainSync` blocks, including the socket-command
/// focus-allowance policy stack the helper threads through). The conformer holds
/// only a `weak` reference to the app-lifetime controller singleton; it is read on
/// the worker thread, so the type is `Sendable` with a `nonisolated(unsafe)`
/// stored `weak` (the controller outlives every socket command).
struct TerminalControllerSidebarSimulateDragReading: ControlSidebarSimulateDragReading {
    /// The controller whose live sidebar/tab state backs the seam. `weak` so the
    /// worker never extends the controller's lifetime; read on the worker thread.
    private nonisolated(unsafe) weak var owner: TerminalController?

    /// The composition-root-owned debug per-window drag-state registry, injected
    /// at construction instead of reached via `AppDelegate.shared`. `weak` so the
    /// reader never extends the app-lifetime registry's lifetime, matching the
    /// `AppDelegate.shared?` optional-chaining the legacy reads performed; held by
    /// the worker-thread `Sendable` struct but read only inside the `owner`'s
    /// `v2MainSync` main-actor hops, exactly like `owner`.
    private nonisolated(unsafe) weak var registry: SidebarDragStateRegistry?

    /// Creates a conformer.
    ///
    /// - Parameters:
    ///   - owner: The controller whose live sidebar state backs the seam.
    ///   - registry: The composition-root-owned per-window drag-state registry the
    ///     reader resolves mounted sidebars through.
    init(owner: TerminalController, registry: SidebarDragStateRegistry?) {
        self.owner = owner
        self.registry = registry
    }

    func plan(params: [String: JSONValue]) -> ControlSidebarSimulateDragPlanOutcome {
        guard let owner else {
            return .error(code: "not_found", message: "No TabManager for window_id", data: nil)
        }
        // The legacy plan block ran inside one v2MainSync and resolved the request
        // params with the app param helpers (which take `[String: Any]`). Convert
        // the typed params back to the Foundation shape `request.params` carried so
        // the resolution is byte-identical.
        let foundationParams = params.mapValues(\.foundationObject)
        return owner.v2MainSync {
            guard let windowId = owner.v2UUID(foundationParams, "window_id") else {
                return .error(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
            }
            // Scope to the requested window. owner.tabManager is the controller's
            // primary tabManager; in multi-window runs that's the wrong list for
            // a window_id other than the primary.
            guard let windowTabManager = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                return .error(
                    code: "not_found",
                    message: "No TabManager for window_id",
                    data: .object(["window_id": .string(windowId.uuidString)])
                )
            }
            guard let fromTabId = owner.v2UUID(foundationParams, "from_tab_id") else {
                return .error(code: "invalid_params", message: "Missing or invalid from_tab_id", data: nil)
            }
            guard let toTabId = owner.v2UUID(foundationParams, "to_tab_id") else {
                return .error(code: "invalid_params", message: "Missing or invalid to_tab_id", data: nil)
            }
            let durationMs: Int
            if owner.v2HasNonNullParam(foundationParams, "duration_ms") {
                guard let value = owner.v2Int(foundationParams, "duration_ms"), value > 0 else {
                    return .error(code: "invalid_params", message: "duration_ms must be a positive integer", data: nil)
                }
                durationMs = value
            } else {
                durationMs = 1000
            }
            let requestedSteps: Int?
            if owner.v2HasNonNullParam(foundationParams, "steps") {
                guard let value = owner.v2Int(foundationParams, "steps"), value > 0 else {
                    return .error(code: "invalid_params", message: "steps must be a positive integer", data: nil)
                }
                requestedSteps = value
            } else {
                requestedSteps = nil
            }
            guard registry?.state(forWindowId: windowId) != nil else {
                return .error(
                    code: "not_found",
                    message: "No mounted sidebar for window_id",
                    data: .object(["window_id": .string(windowId.uuidString)])
                )
            }
            let tabIds = windowTabManager.tabs.map(\.id)
            guard let fromIndex = tabIds.firstIndex(of: fromTabId) else {
                return .error(
                    code: "not_found",
                    message: "from_tab_id not in window's workspace list",
                    data: .object(["from_tab_id": .string(fromTabId.uuidString)])
                )
            }
            guard let toIndex = tabIds.firstIndex(of: toTabId) else {
                return .error(
                    code: "not_found",
                    message: "to_tab_id not in window's workspace list",
                    data: .object(["to_tab_id": .string(toTabId.uuidString)])
                )
            }
            guard fromIndex != toIndex else {
                return .error(code: "invalid_params", message: "from_tab_id and to_tab_id must differ", data: nil)
            }
            return .plan(
                ControlSidebarSimulateDragPlan(
                    windowId: windowId,
                    fromTabId: fromTabId,
                    toTabId: toTabId,
                    tabIds: tabIds,
                    fromIndex: fromIndex,
                    toIndex: toIndex,
                    durationMs: durationMs,
                    requestedSteps: requestedSteps
                )
            )
        }
    }

    func begin(windowId: UUID, fromTabId: UUID) -> Bool {
        guard let owner else { return false }
        return owner.v2MainSync {
            guard let dragState = registry?.state(forWindowId: windowId) else { return false }
            // Mark the drag as simulator-driven so VerticalTabsSidebar skips
            // starting SidebarDragFailsafeMonitor — it would otherwise post
            // mouse_up_failsafe immediately because no real mouse is pressed.
            dragState.isSimulated = true
            dragState.beginDragging(tabId: fromTabId)
            return true
        }
    }

    func tick(windowId: UUID, tabId: UUID, edgeIsBottom: Bool) -> Bool {
        guard let owner else { return false }
        let edge: SidebarDropEdge = edgeIsBottom ? .bottom : .top
        return owner.v2MainSync {
            guard let dragState = registry?.state(forWindowId: windowId) else { return false }
            dragState.setDropIndicator(SidebarDropIndicator(tabId: tabId, edge: edge))
            return true
        }
    }

    func clear(windowId: UUID) {
        guard let owner else { return }
        owner.v2MainSync {
            guard let dragState = registry?.state(forWindowId: windowId) else { return }
            dragState.clearDrag()
            dragState.isSimulated = false
        }
    }
}
#endif
