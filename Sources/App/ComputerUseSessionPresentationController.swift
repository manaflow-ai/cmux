import Foundation

/// Owns each Computer Use session's focus intent, cursor visibility, and effect
/// epochs. Focus changes preserve the active helper cursor; foreground window
/// ordering occludes or reveals its target-relative overlay without cycling it.
@MainActor
final class ComputerUseSessionPresentationController {
    private static let defaultActiveFocusMode =
        ComputerUseWatchFocusMode.callingTerminal

    typealias EffectValidity = @MainActor @Sendable () -> Bool
    typealias CursorVisibilityEffect = @MainActor @Sendable (
        _ driverSessionID: String,
        _ proxySessionID: String?,
        _ visible: Bool,
        _ isCurrent: @escaping EffectValidity
    ) async -> Void
    typealias TerminalFocusEffect = @MainActor (
        _ workspaceID: UUID,
        _ surfaceID: UUID,
        _ isCurrent: @escaping EffectValidity
    ) -> Void
    typealias CursorReassertEffect = @MainActor @Sendable (
        _ driverSessionID: String,
        _ proxySessionID: String?,
        _ targetWindowID: UInt32?,
        _ isCurrent: @escaping EffectValidity
    ) async -> Void

    private enum ActivityPhase: Equatable {
        case active
        /// The turn ended, but the stable cursor identity remains reusable.
        case hiddenReusable
        /// The owning driver/session disappeared. A later start explicitly
        /// revives the stable identity and receives a fresh cursor epoch.
        case ended
    }

    private struct SessionState: Equatable {
        var activityPhase: ActivityPhase
        var focusMode: ComputerUseWatchFocusMode
        var cursorVisible: Bool
        var proxySessionID: String?
        var cursorEffectProxySessionID: String?
        var targetWindowID: UInt32?
        var focusEpoch: UInt64
        var cursorEpoch: UInt64
    }

    private let setCursorVisibility: CursorVisibilityEffect
    private let focusTerminal: TerminalFocusEffect
    private let reassertCursor: CursorReassertEffect
    private var statesByDriverSessionID: [String: SessionState] = [:]
    private var focusTasksByDriverSessionID: [String: Task<Void, Never>] = [:]
    private var cursorTasksByDriverSessionID: [String: Task<Void, Never>] = [:]
    private var reassertTasksByDriverSessionID: [String: Task<Void, Never>] = [:]
    private var nextEpoch: UInt64 = 0

    init(
        setCursorVisibility: @escaping CursorVisibilityEffect,
        focusTerminal: @escaping TerminalFocusEffect,
        reassertCursor: @escaping CursorReassertEffect = { _, _, _, _ in }
    ) {
        self.setCursorVisibility = setCursorVisibility
        self.focusTerminal = focusTerminal
        self.reassertCursor = reassertCursor
    }

    func stop() {
        for task in focusTasksByDriverSessionID.values {
            task.cancel()
        }
        focusTasksByDriverSessionID.removeAll()
        for task in cursorTasksByDriverSessionID.values {
            task.cancel()
        }
        cursorTasksByDriverSessionID.removeAll()
        for task in reassertTasksByDriverSessionID.values {
            task.cancel()
        }
        reassertTasksByDriverSessionID.removeAll()
        statesByDriverSessionID.removeAll()
    }

    func driverSessionDidStart(
        _ driverSessionID: String,
        proxySessionID: String? = nil
    ) {
        let previous = statesByDriverSessionID[driverSessionID]
        var state = activeState(for: driverSessionID)
        state.activityPhase = .active
        state.cursorVisible = true
        state.proxySessionID = proxySessionID ?? state.proxySessionID
        let shouldScheduleCursorEffect =
            previous == nil
                || previous?.activityPhase == .hiddenReusable
                || previous?.activityPhase == .ended
                || previous?.cursorVisible == false
                || state.cursorEffectProxySessionID
                    != state.proxySessionID
        guard shouldScheduleCursorEffect else {
            statesByDriverSessionID[driverSessionID] = state
            return
        }
        state.cursorEffectProxySessionID = state.proxySessionID
        assignNextCursorEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        scheduleCursorEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            visible: state.cursorVisible,
            epoch: state.cursorEpoch
        )
    }

    func focusCallingTerminal(
        driverSessionID: String,
        workspaceID: UUID,
        surfaceID: UUID,
        proxySessionID: String? = nil,
        targetWindowID: UInt32? = nil
    ) {
        var state = activeState(for: driverSessionID)
        state.activityPhase = .active
        state.focusMode = .callingTerminal
        // Keep the cursor rendered behind cmux so returning to the target reveals
        // the existing overlay immediately instead of waiting on a helper RPC.
        state.cursorVisible = true
        state.proxySessionID = proxySessionID ?? state.proxySessionID
        state.targetWindowID = targetWindowID ?? state.targetWindowID
        assignNextFocusEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        let isCurrent = focusValidity(
            driverSessionID: driverSessionID,
            epoch: state.focusEpoch
        )
        scheduleFocusEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            targetWindowID: state.targetWindowID,
            epoch: state.focusEpoch,
            isCurrent: isCurrent
        ) { [focusTerminal] in
            focusTerminal(workspaceID, surfaceID, isCurrent)
        }
    }

    func focusComputerUse(
        driverSessionID: String,
        proxySessionID: String? = nil,
        targetWindowID: UInt32? = nil,
        activate: @escaping @MainActor () -> Void
    ) {
        var state = activeState(for: driverSessionID)
        state.activityPhase = .active
        state.focusMode = .computerUse
        // The active overlay was never disabled while cmux was foregrounded.
        state.cursorVisible = true
        state.proxySessionID = proxySessionID ?? state.proxySessionID
        state.targetWindowID = targetWindowID ?? state.targetWindowID
        assignNextFocusEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        let isCurrent = focusValidity(
            driverSessionID: driverSessionID,
            epoch: state.focusEpoch
        )
        scheduleFocusEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            targetWindowID: state.targetWindowID,
            epoch: state.focusEpoch,
            isCurrent: isCurrent
        ) {
            activate()
        }
    }

    func reassertCallingTerminal(
        driverSessionID: String,
        workspaceID: UUID,
        surfaceID: UUID,
        targetWindowID: UInt32? = nil
    ) {
        guard var state = statesByDriverSessionID[driverSessionID],
            state.activityPhase == .active,
            state.focusMode == .callingTerminal
        else {
            return
        }
        state.targetWindowID = targetWindowID ?? state.targetWindowID
        statesByDriverSessionID[driverSessionID] = state
        let isCurrent = focusValidity(
            driverSessionID: driverSessionID,
            epoch: state.focusEpoch
        )
        scheduleFocusEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            targetWindowID: state.targetWindowID,
            epoch: state.focusEpoch,
            isCurrent: isCurrent
        ) { [focusTerminal] in
            focusTerminal(workspaceID, surfaceID, isCurrent)
        }
    }

    func activateTarget(
        driverSessionID: String,
        targetWindowID: UInt32? = nil,
        activate: @MainActor () -> Void
    ) {
        var state = statesByDriverSessionID[driverSessionID]
            ?? SessionState(
                activityPhase: .active,
                focusMode: Self.defaultActiveFocusMode,
                cursorVisible: true,
                proxySessionID: nil,
                cursorEffectProxySessionID: nil,
                targetWindowID: nil,
                focusEpoch: 0,
                cursorEpoch: 0
            )
        state.targetWindowID = targetWindowID ?? state.targetWindowID
        if statesByDriverSessionID[driverSessionID] == nil {
            statesByDriverSessionID[driverSessionID] = state
        } else {
            statesByDriverSessionID[driverSessionID] = state
        }
        guard
            state.activityPhase == .active,
            state.focusMode != .callingTerminal
        else {
            return
        }
        activate()
        scheduleCursorReassertion(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            targetWindowID: state.targetWindowID,
            epoch: state.focusEpoch
        )
    }

    func driverSessionDidComplete(
        _ driverSessionID: String,
        proxySessionID: String? = nil
    ) {
        var state = statesByDriverSessionID[driverSessionID]
            ?? SessionState(
                activityPhase: .active,
                focusMode: Self.defaultActiveFocusMode,
                cursorVisible: true,
                proxySessionID: nil,
                cursorEffectProxySessionID: nil,
                targetWindowID: nil,
                focusEpoch: 0,
                cursorEpoch: 0
            )
        let resolvedProxySessionID =
            proxySessionID ?? state.proxySessionID
        let shouldScheduleCursorEffect =
            state.activityPhase != .hiddenReusable
                || state.cursorVisible
                || state.cursorEffectProxySessionID
                    != resolvedProxySessionID
        state.activityPhase = .hiddenReusable
        state.focusMode = .automatic
        state.cursorVisible = false
        state.proxySessionID = resolvedProxySessionID
        state.targetWindowID = nil
        assignNextFocusEpoch(to: &state)
        focusTasksByDriverSessionID[driverSessionID]?.cancel()
        focusTasksByDriverSessionID.removeValue(
            forKey: driverSessionID
        )
        cursorTasksByDriverSessionID[driverSessionID]?.cancel()
        cursorTasksByDriverSessionID.removeValue(forKey: driverSessionID)
        reassertTasksByDriverSessionID[driverSessionID]?.cancel()
        reassertTasksByDriverSessionID.removeValue(forKey: driverSessionID)
        guard shouldScheduleCursorEffect else {
            statesByDriverSessionID[driverSessionID] = state
            return
        }
        state.cursorEffectProxySessionID = resolvedProxySessionID
        assignNextCursorEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        scheduleCursorEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            visible: false,
            epoch: state.cursorEpoch
        )
    }

    /// Retires the whole driver generation after the live-session projection
    /// confirms that its owner is gone. The cursor is still hidden through the
    /// same idempotent path, but the phase records that a future start is a new
    /// lifecycle rather than another turn on the current owner.
    func driverSessionDidEnd(
        _ driverSessionID: String,
        proxySessionID: String? = nil
    ) {
        driverSessionDidComplete(
            driverSessionID,
            proxySessionID: proxySessionID
        )
        guard var state = statesByDriverSessionID[driverSessionID] else {
            return
        }
        state.activityPhase = .ended
        statesByDriverSessionID[driverSessionID] = state
    }

    func proxySessionDidBecomeKnown(
        driverSessionID: String,
        proxySessionID: String,
        targetWindowID: UInt32? = nil
    ) {
        var state = statesByDriverSessionID[driverSessionID]
            ?? SessionState(
                activityPhase: .active,
                focusMode: Self.defaultActiveFocusMode,
                cursorVisible: true,
                proxySessionID: nil,
                cursorEffectProxySessionID: nil,
                targetWindowID: nil,
                focusEpoch: 0,
                cursorEpoch: 0
            )
        guard
            state.proxySessionID != proxySessionID
                || state.cursorEffectProxySessionID != proxySessionID
        else {
            return
        }
        state.proxySessionID = proxySessionID
        state.targetWindowID = targetWindowID ?? state.targetWindowID
        state.cursorEffectProxySessionID = proxySessionID
        assignNextCursorEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        scheduleCursorEffect(
            driverSessionID: driverSessionID,
            proxySessionID: proxySessionID,
            visible: state.cursorVisible,
            epoch: state.cursorEpoch
        )
    }

    func focusMode(for driverSessionID: String) -> ComputerUseWatchFocusMode {
        guard
            let state = statesByDriverSessionID[driverSessionID],
            state.activityPhase == .active
        else {
            return .automatic
        }
        return state.focusMode
    }

    func isRunningInBackground(_ driverSessionID: String) -> Bool {
        focusMode(for: driverSessionID) == .callingTerminal
    }

    private func activeState(for driverSessionID: String) -> SessionState {
        guard var state = statesByDriverSessionID[driverSessionID] else {
            return SessionState(
                activityPhase: .active,
                focusMode: Self.defaultActiveFocusMode,
                cursorVisible: true,
                proxySessionID: nil,
                cursorEffectProxySessionID: nil,
                targetWindowID: nil,
                focusEpoch: 0,
                cursorEpoch: 0
            )
        }
        if state.activityPhase != .active {
            state.focusMode = Self.defaultActiveFocusMode
            state.cursorVisible = true
        }
        state.activityPhase = .active
        return state
    }

    private func assignNextFocusEpoch(to state: inout SessionState) {
        nextEpoch &+= 1
        state.focusEpoch = nextEpoch
    }

    private func assignNextCursorEpoch(to state: inout SessionState) {
        nextEpoch &+= 1
        state.cursorEpoch = nextEpoch
    }

    private func focusValidity(
        driverSessionID: String,
        epoch: UInt64
    ) -> EffectValidity {
        { @MainActor [weak self] in
            self?.statesByDriverSessionID[driverSessionID]?.focusEpoch
                == epoch
        }
    }

    private func cursorValidity(
        driverSessionID: String,
        epoch: UInt64
    ) -> EffectValidity {
        { @MainActor [weak self] in
            self?.statesByDriverSessionID[driverSessionID]?.cursorEpoch
                == epoch
        }
    }

    /// Status-item actions arrive while AppKit is still tracking the menu.
    /// Recording the epoch synchronously makes the selected mode authoritative;
    /// scheduling the effect on the next main-actor turn lets menu dismissal
    /// finish first. Replacing the task guarantees that a rapid mode switch
    /// cannot apply an older focus choice after the newer one.
    private func scheduleFocusEffect(
        driverSessionID: String,
        proxySessionID: String?,
        targetWindowID: UInt32?,
        epoch: UInt64,
        isCurrent: @escaping EffectValidity,
        effect: @escaping @MainActor () -> Void
    ) {
        focusTasksByDriverSessionID[driverSessionID]?.cancel()
        reassertTasksByDriverSessionID[driverSessionID]?.cancel()
        focusTasksByDriverSessionID[driverSessionID] = Task { @MainActor in
            guard !Task.isCancelled, isCurrent() else { return }
            effect()
            guard !Task.isCancelled, isCurrent() else { return }
            // Focus activation is the visible part of this interaction. Do
            // not hold the menu/focus task open while the helper processes
            // several authenticated socket requests (native + compatibility
            // profiles). Queue the repair independently so returning focus is
            // immediate; its epoch guard still prevents an older selection
            // from repinning a newer target.
            self.scheduleCursorReassertion(
                driverSessionID: driverSessionID,
                proxySessionID: proxySessionID,
                targetWindowID: targetWindowID,
                epoch: epoch
            )
        }
    }

    private func scheduleCursorReassertion(
        driverSessionID: String,
        proxySessionID: String?,
        targetWindowID: UInt32?,
        epoch: UInt64
    ) {
        guard targetWindowID != nil else { return }
        reassertTasksByDriverSessionID[driverSessionID]?.cancel()
        let isCurrent = focusValidity(
            driverSessionID: driverSessionID,
            epoch: epoch
        )
        let reassertCursor = self.reassertCursor
        reassertTasksByDriverSessionID[driverSessionID] = Task { @MainActor in
            guard !Task.isCancelled, isCurrent() else { return }
            await reassertCursor(
                driverSessionID,
                proxySessionID,
                targetWindowID,
                isCurrent
            )
        }
    }

    private func scheduleCursorEffect(
        driverSessionID: String,
        proxySessionID: String?,
        visible: Bool,
        epoch: UInt64
    ) {
        cursorTasksByDriverSessionID[driverSessionID]?.cancel()
        let isCurrent = cursorValidity(
            driverSessionID: driverSessionID,
            epoch: epoch
        )
        let setCursorVisibility = self.setCursorVisibility
        cursorTasksByDriverSessionID[driverSessionID] = Task { @MainActor in
            guard !Task.isCancelled, isCurrent() else { return }
            await setCursorVisibility(
                driverSessionID,
                proxySessionID,
                visible,
                isCurrent
            )
        }
    }
}
