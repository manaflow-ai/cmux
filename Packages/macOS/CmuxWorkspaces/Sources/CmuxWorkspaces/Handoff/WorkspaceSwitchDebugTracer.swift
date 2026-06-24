#if DEBUG
public import Foundation
import CmuxFoundation
import Observation
import QuartzCore

/// Per-window `#if DEBUG` workspace-switch telemetry sub-model.
///
/// `TabManager` used to carry the six transient workspace-switch trace fields
/// (the monotonic switch counter, the current switch id, the switch start time,
/// and the pending/prepared trigger+target cursors) inline alongside a handful
/// of `debug*` methods that the selection `willSet`/`didSet`, the workspace
/// cycle-hot transitions, and the create/focus/select priming paths drove. This
/// sub-model owns that telemetry state so the god object only holds a reference
/// and forwards.
///
/// **What it tracks.** The `ws.switch.begin`, `ws.select.didSet`,
/// `ws.select.asyncDone`, and `ws.hot.*` debug trace lines all key off a single
/// in-flight "switch" identity: ``currentSwitchId`` (monotonic, assigned by
/// ``beginWorkspaceSwitch(trigger:from:to:isCycleHot:tabCount:)``) and
/// ``switchStartTime`` (a `CACurrentMediaTime` stamp, the `dt=` baseline). The
/// pending/prepared cursors (``pendingSwitchTrigger`` / ``pendingSwitchTarget``
/// / ``preparedSwitchTarget``) let an entrypoint that knows *why* a switch is
/// about to happen (create, focus, select, cycle) prime the trigger label
/// before the selection actually changes, so the `begin` line reports the real
/// cause instead of the `"direct"` fallback.
///
/// **Isolation design.** `@MainActor` because every mutator and reader is a
/// MainActor UI path: the selection `willSet`/`didSet`, the cycle-hot
/// `.onChange` transitions, and the create/focus/select priming all run on the
/// main actor inside `TabManager`. The state therefore lives on one isolation
/// domain with its callers, so the forwards are plain synchronous calls with no
/// bridging. `@Observable` (not `ObservableObject`) per the refactor migration
/// direction, though nothing observes this sub-model: it is pure write-side
/// telemetry feeding the debug log.
///
/// **Why a sub-model, not a static namespace.** The state is genuinely mutable
/// per-window instance state (a live counter and an in-flight switch identity),
/// so it is a real `@MainActor` instance holding that state and an injected log
/// sink, never a caseless namespace of `static func`s.
///
/// **Log sink.** `cmuxDebugLog` lives in the app target (`Sources/App`), not in
/// a package, so this sub-model takes the app's DEBUG sink as an injected
/// `@Sendable (String) -> Void`, mirroring
/// ``WorkspaceLayoutFollowUpCoordinator``. Release builds never compile this
/// type (`#if DEBUG`), exactly as the original `#if DEBUG`-guarded fields and
/// `cmuxDebugLog` calls were elided in release.
@MainActor
@Observable
public final class WorkspaceSwitchDebugTracer {
    /// Monotonic counter that mints each new switch id.
    private var switchCounter: UInt64 = 0

    /// The id of the in-flight workspace switch, or `0` when none is timed.
    public private(set) var currentSwitchId: UInt64 = 0

    /// `CACurrentMediaTime` stamp when the current switch began, or `0` when no
    /// switch is timed. The baseline for every `dt=` field.
    public private(set) var switchStartTime: CFTimeInterval = 0

    /// The trigger label primed for the next selection change, consumed when the
    /// selection actually moves to ``pendingSwitchTarget``.
    private var pendingSwitchTrigger: String?

    /// The workspace the next selection change is expected to move to, paired
    /// with ``pendingSwitchTrigger``.
    private var pendingSwitchTarget: UUID?

    /// A workspace whose switch was already begun by ``prepareWorkspaceSwitch``
    /// so the selection `willSet` skips re-beginning it.
    private var preparedSwitchTarget: UUID?

    /// The app's DEBUG `cmuxDebugLog` sink. The app passes its sink in DEBUG; the
    /// default no-op keeps the type constructible without one.
    private let debugLog: @Sendable (String) -> Void

    /// Creates the tracer.
    ///
    /// - Parameter debugLog: the app's DEBUG `cmuxDebugLog` sink for the `ws.*`
    ///   trace lines (default no-op; the app passes its sink in DEBUG).
    public init(debugLog: @escaping @Sendable (String) -> Void = { _ in }) {
        self.debugLog = debugLog
    }

    /// Elapsed ms since the current workspace switch started, or `0` when no
    /// switch is timed — the `dt=` field the cycle-hot trace lines report.
    public var cycleSwitchDtMs: Double {
        switchStartTime > 0
            ? (CACurrentMediaTime() - switchStartTime) * 1000
            : 0
    }

    /// The in-flight switch id and its start time, or `nil` when no switch is
    /// timed. Used by the handoff/unfocus trace formatters to prefix `id=<id>
    /// dt=<ms>`.
    public func currentWorkspaceSwitchSnapshot() -> (id: UInt64, startedAt: CFTimeInterval)? {
        guard currentSwitchId > 0, switchStartTime > 0 else { return nil }
        return (currentSwitchId, switchStartTime)
    }

    // MARK: - Priming (create / focus / select / direct)

    /// Primes the trigger label for the next selection change to `target`.
    ///
    /// No-op (and clears any pending cursor) when `selectedWorkspaceId` already
    /// equals `target`, so a re-select does not mislabel the next real switch.
    ///
    /// - Parameters:
    ///   - trigger: the trigger label (`"create"`, `"focus"`, `"select"`, ...).
    ///   - target: the workspace the selection is about to move to.
    ///   - selectedWorkspaceId: the currently selected workspace.
    public func primeWorkspaceSwitchTrigger(
        _ trigger: String,
        to target: UUID?,
        selectedWorkspaceId: UUID?
    ) {
        guard selectedWorkspaceId != target else {
            pendingSwitchTrigger = nil
            pendingSwitchTarget = nil
            return
        }
        pendingSwitchTrigger = trigger
        pendingSwitchTarget = target
    }

    /// Begins a switch ahead of the selection change and records `to` as the
    /// prepared target so the selection `willSet` skips re-beginning it.
    ///
    /// No-op (clearing all cursors) when `from == to`.
    ///
    /// - Parameters:
    ///   - trigger: the trigger label.
    ///   - from: the workspace being switched away from.
    ///   - to: the workspace being switched to.
    ///   - isCycleHot: whether the workspace cycle is hot, for the `hot=` field.
    ///   - tabCount: the current workspace count, for the `tabs=` field.
    public func prepareWorkspaceSwitch(
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
        beginWorkspaceSwitch(
            trigger: trigger,
            from: from,
            to: to,
            isCycleHot: isCycleHot,
            tabCount: tabCount
        )
        preparedSwitchTarget = to
    }

    // MARK: - Selection willSet/didSet hooks

    /// The selection-`willSet` hook: decides whether the impending selection
    /// change to `newValue` should begin a new switch, and with which trigger.
    ///
    /// Mirrors the legacy inline `willSet` logic: a no-op equal-assignment
    /// clears the cursors; a `newValue` already prepared by
    /// ``prepareWorkspaceSwitch`` clears the prepared/pending cursors without
    /// re-beginning; otherwise it begins a switch with the pending trigger
    /// (when it targets `newValue`) or `"direct"`.
    ///
    /// - Parameters:
    ///   - newValue: the workspace the selection is about to change to.
    ///   - selectedWorkspaceId: the currently selected workspace (pre-change).
    ///   - isCycleHot: whether the workspace cycle is hot, for the `hot=` field.
    ///   - tabCount: the current workspace count, for the `tabs=` field.
    public func selectedWorkspaceIdWillChange(
        to newValue: UUID?,
        selectedWorkspaceId: UUID?,
        isCycleHot: Bool,
        tabCount: Int
    ) {
        guard newValue != selectedWorkspaceId else {
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
            beginWorkspaceSwitch(
                trigger: trigger,
                from: selectedWorkspaceId,
                to: newValue,
                isCycleHot: isCycleHot,
                tabCount: tabCount
            )
        }
    }

    /// Emits the `ws.select.didSet` trace line after the selection changed.
    ///
    /// - Parameters:
    ///   - previousWorkspaceId: the workspace selected before the change.
    ///   - selectedWorkspaceId: the workspace selected after the change.
    public func logSelectDidSet(
        previousWorkspaceId: UUID?,
        selectedWorkspaceId: UUID?
    ) {
        let switchId = currentSwitchId
        let switchDtMs = switchStartTime > 0
            ? (CACurrentMediaTime() - switchStartTime) * 1000
            : 0
        debugLog(
            "ws.select.didSet id=\(switchId) from=\(previousWorkspaceId.debugShortWorkspaceId) " +
            "to=\(selectedWorkspaceId.debugShortWorkspaceId) dt=\(switchDtMs.debugMillisecondsText)"
        )
    }

    /// Emits the `ws.select.asyncDone` trace line from the deferred selection
    /// side-effect continuation.
    ///
    /// - Parameter selectedWorkspaceId: the workspace selected when the deferred
    ///   side effects ran.
    public func logSelectAsyncDone(selectedWorkspaceId: UUID?) {
        let dtMs = switchStartTime > 0
            ? (CACurrentMediaTime() - switchStartTime) * 1000
            : 0
        debugLog(
            "ws.select.asyncDone id=\(currentSwitchId) dt=\(dtMs.debugMillisecondsText) " +
            "selected=\(selectedWorkspaceId.debugShortWorkspaceId)"
        )
    }

    // MARK: - Workspace cycle-hot trace forwarders

    /// Emits the `ws.hot.on` trace line for the given cycle generation.
    public func logWorkspaceCycleHotOn(generation: UInt64) {
        debugLog(
            "ws.hot.on id=\(currentSwitchId) gen=\(generation) dt=\(cycleSwitchDtMs.debugMillisecondsText)"
        )
    }

    /// Emits the `ws.hot.cancelPrev` trace line for the given cycle generation.
    public func logWorkspaceCycleHotCancelPrevious(generation: UInt64) {
        debugLog(
            "ws.hot.cancelPrev id=\(currentSwitchId) gen=\(generation) dt=\(cycleSwitchDtMs.debugMillisecondsText)"
        )
    }

    /// Emits the `ws.hot.cooldownCanceled` trace line for the given cycle generation.
    public func logWorkspaceCycleHotCooldownCanceled(generation: UInt64) {
        debugLog(
            "ws.hot.cooldownCanceled id=\(currentSwitchId) gen=\(generation) dt=\(cycleSwitchDtMs.debugMillisecondsText)"
        )
    }

    /// Emits the `ws.hot.off` trace line for the given cycle generation.
    public func logWorkspaceCycleHotOff(generation: UInt64) {
        debugLog(
            "ws.hot.off id=\(currentSwitchId) gen=\(generation) dt=\(cycleSwitchDtMs.debugMillisecondsText)"
        )
    }

    // MARK: - Switch identity

    /// Mints a new switch id, stamps the start time, and emits `ws.switch.begin`.
    ///
    /// - Parameters:
    ///   - trigger: the trigger label.
    ///   - from: the workspace being switched away from.
    ///   - to: the workspace being switched to.
    ///   - isCycleHot: whether the workspace cycle is hot, for the `hot=` field.
    ///   - tabCount: the current workspace count, for the `tabs=` field.
    private func beginWorkspaceSwitch(
        trigger: String,
        from: UUID?,
        to: UUID?,
        isCycleHot: Bool,
        tabCount: Int
    ) {
        switchCounter &+= 1
        currentSwitchId = switchCounter
        switchStartTime = CACurrentMediaTime()
        debugLog(
            "ws.switch.begin id=\(currentSwitchId) trigger=\(trigger) " +
            "from=\(from.debugShortWorkspaceId) to=\(to.debugShortWorkspaceId) " +
            "hot=\(isCycleHot ? 1 : 0) tabs=\(tabCount)"
        )
    }
}
#endif
