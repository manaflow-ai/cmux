#if DEBUG
public import Foundation
import QuartzCore
internal import CMUXDebugLog

/// Per-window DEBUG instrumentation for workspace switches: the switch
/// timer/counter state machine plus the byte-identical `ws.switch.*` /
/// `ws.hot.*` / `ws.select.*` / `ws.unfocus.*` / `ws.handoff.*` /
/// `workspace.title.enqueue` trace-line builders that `TabManager` used to emit
/// inline.
///
/// `TabManager` owns one of these (`workspaceSwitchDebug`) and forwards its
/// legacy `debug*` / `log*` hooks here; the witnesses keep their old names so
/// the multi-file callers (`ContentView`, `GhosttyTerminalView`, and the
/// `CmuxWorkspaces` coordinators via the hosting seams) stay byte-unchanged.
/// The live per-window reads the tracker cannot see for itself
/// (`isWorkspaceCycleHot`, `tabs.count`, `selectedTabId`, and the from/to ids)
/// are passed in as parameters.
///
/// The whole type is `#if DEBUG`: release builds carry no switch-tracking state
/// and the `TabManager` forwarders compile to no-ops, exactly as the original
/// `#if DEBUG`-guarded `cmuxDebugLog` calls did.
@MainActor
public final class WorkspaceSwitchDebugTracker {
    private var switchCounter: UInt64 = 0
    private var switchId: UInt64 = 0
    private var switchStartTime: CFTimeInterval = 0
    private var pendingSwitchTrigger: String?
    private var pendingSwitchTarget: UUID?
    private var preparedSwitchTarget: UUID?

    public init() {}

    /// Elapsed ms since the current switch started, or 0 when no switch is
    /// timed — the `dt=` field the cycle-hot trace lines report.
    private var cycleSwitchDtMs: Double {
        switchStartTime > 0
            ? (CACurrentMediaTime() - switchStartTime) * 1000
            : 0
    }

    /// The active switch's id and start time, or nil when none is timed — the
    /// snapshot `ContentView` and the unfocus/handoff trace builders prepend
    /// (legacy `debugCurrentWorkspaceSwitchSnapshot`).
    public func currentSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        guard switchId > 0, switchStartTime > 0 else { return nil }
        return (switchId, switchStartTime)
    }

    // MARK: - Switch-trigger state machine

    /// Primes a pending switch trigger for the next selection change, or clears
    /// it when the target already equals `currentSelected` (legacy
    /// `debugPrimeWorkspaceSwitchTrigger(_:to:)`).
    public func primeSwitchTrigger(_ trigger: String, to target: UUID?, currentSelected: UUID?) {
        guard currentSelected != target else {
            pendingSwitchTrigger = nil
            pendingSwitchTarget = nil
            return
        }
        pendingSwitchTrigger = trigger
        pendingSwitchTarget = target
    }

    /// Begins a traced switch directly (legacy
    /// `debugPrepareWorkspaceSwitch(_:from:to:)`), clearing any pending prime and
    /// recording the prepared target so the matching `selectedTabId` change does
    /// not start a second timer.
    public func prepareSwitch(
        _ trigger: String,
        from: UUID?,
        to: UUID?,
        isCycleHot: Bool,
        tabCount: Int
    ) {
        guard from != to else {
            pendingSwitchTrigger = nil
            pendingSwitchTarget = nil
            preparedSwitchTarget = nil
            return
        }
        pendingSwitchTrigger = nil
        pendingSwitchTarget = nil
        beginSwitch(trigger: trigger, from: from, to: to, isCycleHot: isCycleHot, tabCount: tabCount)
        preparedSwitchTarget = to
    }

    /// Resolves the trigger for an imminent `selectedTabId` change and starts the
    /// switch timer unless the change was already prepared (legacy DEBUG body of
    /// `selectedWorkspaceIdWillChange`).
    public func noteSelectedWorkspaceWillChange(
        to newValue: UUID?,
        currentSelected: UUID?,
        isCycleHot: Bool,
        tabCount: Int
    ) {
        guard newValue != currentSelected else {
            pendingSwitchTrigger = nil
            pendingSwitchTarget = nil
            preparedSwitchTarget = nil
            return
        }

        if preparedSwitchTarget == newValue {
            preparedSwitchTarget = nil
            pendingSwitchTrigger = nil
            pendingSwitchTarget = nil
        } else {
            let trigger = (pendingSwitchTarget == newValue
                ? pendingSwitchTrigger
                : nil) ?? "direct"
            pendingSwitchTrigger = nil
            pendingSwitchTarget = nil
            beginSwitch(
                trigger: trigger,
                from: currentSelected,
                to: newValue,
                isCycleHot: isCycleHot,
                tabCount: tabCount
            )
        }
    }

    private func beginSwitch(trigger: String, from: UUID?, to: UUID?, isCycleHot: Bool, tabCount: Int) {
        switchCounter &+= 1
        switchId = switchCounter
        switchStartTime = CACurrentMediaTime()
        CMUXDebugLog.logDebugEvent(
            "ws.switch.begin id=\(switchId) trigger=\(trigger) " +
            "from=\(Self.shortWorkspaceId(from)) to=\(Self.shortWorkspaceId(to)) " +
            "hot=\(isCycleHot ? 1 : 0) tabs=\(tabCount)"
        )
    }

    // MARK: - Selection-change traces

    /// Legacy `ws.select.didSet`, emitted from the selection willSet/didSet seam.
    public func logSelectionDidChange(from previousTabId: UUID?, to selectedTabId: UUID?) {
        let switchId = self.switchId
        let switchDtMs = switchStartTime > 0
            ? (CACurrentMediaTime() - switchStartTime) * 1000
            : 0
        CMUXDebugLog.logDebugEvent(
            "ws.select.didSet id=\(switchId) from=\(Self.shortWorkspaceId(previousTabId)) " +
            "to=\(Self.shortWorkspaceId(selectedTabId)) dt=\(Self.msText(switchDtMs))"
        )
    }

    /// Legacy `ws.select.asyncDone`, emitted after the selection side effects run.
    public func logSelectionSideEffectsDone(selected selectedTabId: UUID?) {
        let dtMs = switchStartTime > 0
            ? (CACurrentMediaTime() - switchStartTime) * 1000
            : 0
        CMUXDebugLog.logDebugEvent(
            "ws.select.asyncDone id=\(switchId) dt=\(Self.msText(dtMs)) " +
            "selected=\(Self.shortWorkspaceId(selectedTabId))"
        )
    }

    // MARK: - Cycle-hot traces

    /// Legacy `ws.hot.on`.
    public func logCycleHotOn(generation: UInt64) {
        CMUXDebugLog.logDebugEvent(
            "ws.hot.on id=\(switchId) gen=\(generation) dt=\(Self.msText(cycleSwitchDtMs))"
        )
    }

    /// Legacy `ws.hot.cancelPrev`.
    public func logCycleHotCancelPrevious(generation: UInt64) {
        CMUXDebugLog.logDebugEvent(
            "ws.hot.cancelPrev id=\(switchId) gen=\(generation) dt=\(Self.msText(cycleSwitchDtMs))"
        )
    }

    /// Legacy `ws.hot.cooldownCanceled`.
    public func logCycleHotCooldownCanceled(generation: UInt64) {
        CMUXDebugLog.logDebugEvent(
            "ws.hot.cooldownCanceled id=\(switchId) gen=\(generation) dt=\(Self.msText(cycleSwitchDtMs))"
        )
    }

    /// Legacy `ws.hot.off`.
    public func logCycleHotOff(generation: UInt64) {
        CMUXDebugLog.logDebugEvent(
            "ws.hot.off id=\(switchId) gen=\(generation) dt=\(Self.msText(cycleSwitchDtMs))"
        )
    }

    // MARK: - Panel-title trace

    /// Legacy `workspace.title.enqueue`.
    public func logPanelTitleEnqueue(workspaceId: UUID, panelId: UUID, title: String) {
        CMUXDebugLog.logDebugEvent(
            "workspace.title.enqueue workspace=\(Self.shortWorkspaceId(workspaceId)) " +
            "panel=\(panelId.uuidString.prefix(5)) title=\"\(Self.titlePreview(title))\""
        )
    }

    // MARK: - Deferred-unfocus traces

    /// Formats the byte-identical legacy `ws.unfocus.*` trace line for the
    /// decision the ``FocusedSurfaceModel`` reported.
    public func logPendingWorkspaceUnfocus(_ event: PendingWorkspaceUnfocusEvent) {
        switch event {
        case let .deferred(workspaceId, panelId):
            if let snapshot = currentSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                CMUXDebugLog.logDebugEvent(
                    "ws.unfocus.defer id=\(snapshot.id) dt=\(Self.msText(dtMs)) " +
                    "tab=\(Self.shortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5)))"
                )
            } else {
                CMUXDebugLog.logDebugEvent(
                    "ws.unfocus.defer id=none tab=\(Self.shortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5)))"
                )
            }
        case let .flushedOnReplace(workspaceId, panelId):
            CMUXDebugLog.logDebugEvent(
                "ws.unfocus.flush tab=\(Self.shortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5))) reason=replaced"
            )
        case let .droppedOnReplaceSelected(workspaceId, panelId):
            CMUXDebugLog.logDebugEvent(
                "ws.unfocus.drop tab=\(Self.shortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5))) reason=replaced_selected"
            )
        case let .droppedSelectedAgain(workspaceId, panelId):
            CMUXDebugLog.logDebugEvent(
                "ws.unfocus.drop tab=\(Self.shortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5))) reason=selected_again"
            )
        case let .completed(workspaceId, panelId, reason):
            if let snapshot = currentSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                CMUXDebugLog.logDebugEvent(
                    "ws.unfocus.complete id=\(snapshot.id) dt=\(Self.msText(dtMs)) " +
                    "tab=\(Self.shortWorkspaceId(workspaceId)) panel=\(String(panelId.uuidString.prefix(5))) reason=\(reason)"
                )
            } else {
                CMUXDebugLog.logDebugEvent(
                    "ws.unfocus.complete id=none tab=\(Self.shortWorkspaceId(workspaceId)) " +
                    "panel=\(String(panelId.uuidString.prefix(5))) reason=\(reason)"
                )
            }
        }
    }

    // MARK: - Mount/handoff traces

    /// Formats the byte-identical legacy `ws.mount.reconcile` / `ws.handoff.*`
    /// trace line for the transition the ``WorkspaceHandoffCoordinator`` reported.
    public func logWorkspaceHandoff(_ event: WorkspaceHandoffEvent) {
        switch event {
        case let .mountReconciled(isCycleHot, selectedWorkspaceId, mountedWorkspaceIds, addedWorkspaceIds, removedWorkspaceIds):
            if let snapshot = currentSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                CMUXDebugLog.logDebugEvent(
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(Self.msText(dtMs)) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(Self.shortWorkspaceId(selectedWorkspaceId)) " +
                    "mounted=\(Self.shortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(Self.shortWorkspaceIds(addedWorkspaceIds)) removed=\(Self.shortWorkspaceIds(removedWorkspaceIds))"
                )
            } else {
                CMUXDebugLog.logDebugEvent(
                    "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(Self.shortWorkspaceId(selectedWorkspaceId)) " +
                    "mounted=\(Self.shortWorkspaceIds(mountedWorkspaceIds))"
                )
            }
        case let .handoffStarted(oldSelectedWorkspaceId, newSelectedWorkspaceId):
            if let snapshot = currentSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                CMUXDebugLog.logDebugEvent(
                    "ws.handoff.start id=\(snapshot.id) dt=\(Self.msText(dtMs)) old=\(Self.shortWorkspaceId(oldSelectedWorkspaceId)) " +
                    "new=\(Self.shortWorkspaceId(newSelectedWorkspaceId))"
                )
            } else {
                CMUXDebugLog.logDebugEvent(
                    "ws.handoff.start id=none old=\(Self.shortWorkspaceId(oldSelectedWorkspaceId)) new=\(Self.shortWorkspaceId(newSelectedWorkspaceId))"
                )
            }
        case let .handoffFastReady(selectedWorkspaceId):
            if let snapshot = currentSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                CMUXDebugLog.logDebugEvent(
                    "ws.handoff.fastReady id=\(snapshot.id) dt=\(Self.msText(dtMs)) selected=\(Self.shortWorkspaceId(selectedWorkspaceId))"
                )
            } else {
                CMUXDebugLog.logDebugEvent("ws.handoff.fastReady id=none selected=\(Self.shortWorkspaceId(selectedWorkspaceId))")
            }
        case let .handoffCompleted(reason, retiringWorkspaceId):
            if let snapshot = currentSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                CMUXDebugLog.logDebugEvent(
                    "ws.handoff.complete id=\(snapshot.id) dt=\(Self.msText(dtMs)) reason=\(reason) retiring=\(Self.shortWorkspaceId(retiringWorkspaceId))"
                )
            } else {
                CMUXDebugLog.logDebugEvent("ws.handoff.complete id=none reason=\(reason) retiring=\(Self.shortWorkspaceId(retiringWorkspaceId))")
            }
        }
    }

    // MARK: - Formatters

    private static func shortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private static func shortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }

    private static func titlePreview(_ title: String, limit: Int = 120) -> String {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard escaped.count > limit else { return escaped }
        return "\(escaped.prefix(limit))..."
    }

    private static func msText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
}
#endif
