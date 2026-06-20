public import Foundation

/// The resolved, validated plan for one `debug.sidebar.simulate_drag` run, the
/// Sendable snapshot returned by ``ControlSidebarSimulateDragReading/plan(params:)``.
///
/// The app-side seam resolves the request params on the main actor (window-id /
/// tab-id ref resolution, the per-window `TabManager` lookup, the mounted-sidebar
/// guard, the from/to index lookup, and the `duration_ms` / `steps` defaults) and
/// hands the worker-lane ``ControlSidebarSimulateDragWorker`` this fully-resolved
/// plan. The worker owns the off-main resampling, the inter-tick `Thread.sleep`
/// loop, and the reply-payload shaping; it never re-reads the live tab list.
///
/// The fields mirror the legacy `v2DebugSidebarSimulateDrag` plan tuple
/// byte-for-byte: `tabIds` is the window's workspace list (so the worker can map a
/// resolved path index back to a tab id without another main hop), and
/// `requestedSteps` is `nil` when the `steps` param was absent (the worker then
/// defaults to the path length).
public struct ControlSidebarSimulateDragPlan: Sendable {
    /// The target window's id.
    public let windowId: UUID
    /// The dragged tab's id.
    public let fromTabId: UUID
    /// The drop-target tab's id.
    public let toTabId: UUID
    /// The window's workspace tab ids, in order (the legacy `tabManager.tabs.map(\.id)`).
    public let tabIds: [UUID]
    /// The dragged tab's index in `tabIds`.
    public let fromIndex: Int
    /// The drop-target tab's index in `tabIds`.
    public let toIndex: Int
    /// The total simulated drag duration in milliseconds (defaulted to 1000 when absent).
    public let durationMs: Int
    /// The requested step count, or `nil` when the `steps` param was absent.
    public let requestedSteps: Int?

    /// Creates a resolved plan.
    ///
    /// - Parameters:
    ///   - windowId: The target window's id.
    ///   - fromTabId: The dragged tab's id.
    ///   - toTabId: The drop-target tab's id.
    ///   - tabIds: The window's workspace tab ids, in order.
    ///   - fromIndex: The dragged tab's index in `tabIds`.
    ///   - toIndex: The drop-target tab's index in `tabIds`.
    ///   - durationMs: The total simulated drag duration in milliseconds.
    ///   - requestedSteps: The requested step count, or `nil` when absent.
    public init(
        windowId: UUID,
        fromTabId: UUID,
        toTabId: UUID,
        tabIds: [UUID],
        fromIndex: Int,
        toIndex: Int,
        durationMs: Int,
        requestedSteps: Int?
    ) {
        self.windowId = windowId
        self.fromTabId = fromTabId
        self.toTabId = toTabId
        self.tabIds = tabIds
        self.fromIndex = fromIndex
        self.toIndex = toIndex
        self.durationMs = durationMs
        self.requestedSteps = requestedSteps
    }
}

/// The outcome of resolving a `debug.sidebar.simulate_drag` request: either a
/// validated ``ControlSidebarSimulateDragPlan`` or the legacy typed error
/// (code / message / optional data) the plan step produced.
///
/// `data` is `JSONValue?` (the legacy `[String: Any]?` error payloads were all
/// single-key objects, e.g. `["window_id": …]`, built app-side as
/// `.object([…])`) so the error crosses the worker seam without a Foundation
/// round-trip and the worker emits it through
/// ``ControlCallResult/err(code:message:data:)`` unchanged.
public enum ControlSidebarSimulateDragPlanOutcome: Sendable {
    /// The request resolved to a runnable plan.
    case plan(ControlSidebarSimulateDragPlan)
    /// The request failed validation with the legacy error shape.
    case error(code: String, message: String, data: JSONValue?)
}
