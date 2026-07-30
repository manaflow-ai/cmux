import Foundation

/// Owns each Computer Use session's focus intent, cursor visibility, and effect epoch.
@MainActor
final class ComputerUseSessionPresentationController {
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

    private enum ActivityPhase: Equatable {
        case active
        case completed
    }

    private struct SessionState: Equatable {
        var activityPhase: ActivityPhase
        var focusMode: ComputerUseWatchFocusMode
        var cursorVisible: Bool
        var proxySessionID: String?
        var epoch: UInt64
    }

    private let setCursorVisibility: CursorVisibilityEffect
    private let focusTerminal: TerminalFocusEffect
    private var statesByDriverSessionID: [String: SessionState] = [:]
    private var cursorTasksByDriverSessionID: [String: Task<Void, Never>] = [:]
    private var nextEpoch: UInt64 = 0

    init(
        setCursorVisibility: @escaping CursorVisibilityEffect,
        focusTerminal: @escaping TerminalFocusEffect
    ) {
        self.setCursorVisibility = setCursorVisibility
        self.focusTerminal = focusTerminal
    }

    func stop() {
        for task in cursorTasksByDriverSessionID.values {
            task.cancel()
        }
        cursorTasksByDriverSessionID.removeAll()
        statesByDriverSessionID.removeAll()
    }

    func driverSessionDidStart(
        _ driverSessionID: String,
        proxySessionID: String? = nil
    ) {
        var state = activeState(for: driverSessionID)
        state.activityPhase = .active
        state.cursorVisible = state.focusMode != .callingTerminal
        state.proxySessionID = proxySessionID ?? state.proxySessionID
        assignNextEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        scheduleCursorEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            visible: state.cursorVisible,
            epoch: state.epoch
        )
    }

    func focusCallingTerminal(
        driverSessionID: String,
        workspaceID: UUID,
        surfaceID: UUID,
        proxySessionID: String? = nil
    ) {
        var state = activeState(for: driverSessionID)
        state.activityPhase = .active
        state.focusMode = .callingTerminal
        state.cursorVisible = false
        state.proxySessionID = proxySessionID ?? state.proxySessionID
        assignNextEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        let isCurrent = validity(
            driverSessionID: driverSessionID,
            epoch: state.epoch
        )
        scheduleCursorEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            visible: false,
            epoch: state.epoch
        )
        guard isCurrent() else { return }
        focusTerminal(workspaceID, surfaceID, isCurrent)
    }

    func focusComputerUse(
        driverSessionID: String,
        proxySessionID: String? = nil,
        activate: @MainActor () -> Void
    ) {
        var state = activeState(for: driverSessionID)
        state.activityPhase = .active
        state.focusMode = .computerUse
        state.cursorVisible = true
        state.proxySessionID = proxySessionID ?? state.proxySessionID
        assignNextEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        let isCurrent = validity(
            driverSessionID: driverSessionID,
            epoch: state.epoch
        )
        scheduleCursorEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            visible: true,
            epoch: state.epoch
        )
        guard isCurrent() else { return }
        activate()
    }

    func reassertCallingTerminal(
        driverSessionID: String,
        workspaceID: UUID,
        surfaceID: UUID
    ) {
        guard
            let state = statesByDriverSessionID[driverSessionID],
            state.activityPhase == .active,
            state.focusMode == .callingTerminal
        else {
            return
        }
        let isCurrent = validity(
            driverSessionID: driverSessionID,
            epoch: state.epoch
        )
        guard isCurrent() else { return }
        focusTerminal(workspaceID, surfaceID, isCurrent)
    }

    func activateTarget(
        driverSessionID: String,
        activate: @MainActor () -> Void
    ) {
        let state = statesByDriverSessionID[driverSessionID]
            ?? SessionState(
                activityPhase: .active,
                focusMode: .automatic,
                cursorVisible: true,
                proxySessionID: nil,
                epoch: 0
            )
        if statesByDriverSessionID[driverSessionID] == nil {
            statesByDriverSessionID[driverSessionID] = state
        }
        guard
            state.activityPhase == .active,
            state.focusMode != .callingTerminal
        else {
            return
        }
        activate()
    }

    func driverSessionDidComplete(
        _ driverSessionID: String,
        proxySessionID: String? = nil
    ) {
        var state = activeState(for: driverSessionID)
        state.activityPhase = .completed
        state.focusMode = .automatic
        state.cursorVisible = false
        state.proxySessionID = proxySessionID ?? state.proxySessionID
        assignNextEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        scheduleCursorEffect(
            driverSessionID: driverSessionID,
            proxySessionID: state.proxySessionID,
            visible: false,
            epoch: state.epoch
        )
    }

    func proxySessionDidBecomeKnown(
        driverSessionID: String,
        proxySessionID: String
    ) {
        var state = statesByDriverSessionID[driverSessionID]
            ?? SessionState(
                activityPhase: .active,
                focusMode: .automatic,
                cursorVisible: true,
                proxySessionID: nil,
                epoch: 0
            )
        guard state.proxySessionID != proxySessionID else { return }
        state.proxySessionID = proxySessionID
        assignNextEpoch(to: &state)
        statesByDriverSessionID[driverSessionID] = state
        scheduleCursorEffect(
            driverSessionID: driverSessionID,
            proxySessionID: proxySessionID,
            visible: state.cursorVisible,
            epoch: state.epoch
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
                focusMode: .automatic,
                cursorVisible: true,
                proxySessionID: nil,
                epoch: 0
            )
        }
        if state.activityPhase == .completed {
            state.focusMode = .automatic
            state.cursorVisible = true
        }
        state.activityPhase = .active
        return state
    }

    private func assignNextEpoch(to state: inout SessionState) {
        nextEpoch &+= 1
        state.epoch = nextEpoch
    }

    private func validity(
        driverSessionID: String,
        epoch: UInt64
    ) -> EffectValidity {
        { @MainActor [weak self] in
            self?.statesByDriverSessionID[driverSessionID]?.epoch == epoch
        }
    }

    private func scheduleCursorEffect(
        driverSessionID: String,
        proxySessionID: String?,
        visible: Bool,
        epoch: UInt64
    ) {
        cursorTasksByDriverSessionID[driverSessionID]?.cancel()
        let isCurrent = validity(
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
