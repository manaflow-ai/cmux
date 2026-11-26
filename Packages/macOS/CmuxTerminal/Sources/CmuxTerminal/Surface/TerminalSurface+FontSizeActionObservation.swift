internal import GhosttyKit
internal import CmuxTerminalCore

private let terminalGhosttyFontSizeActionCallback:
    ghostty_font_size_action_cb = {
        userdata,
        action,
        previousRuntimePoints,
        currentRuntimePoints,
        previousIsAdjusted,
        currentIsAdjusted in
        guard let userdata else { return }
        let userdataAddress =
            UInt(bitPattern: userdata)
        MainActor.assumeIsolated {
            guard let mainActorUserdata =
                    UnsafeMutableRawPointer(
                        bitPattern: userdataAddress
                    ) else {
                return
            }
            let context =
                Unmanaged<GhosttySurfaceCallbackContext>
                    .fromOpaque(mainActorUserdata)
                    .takeUnretainedValue()
            guard let surface =
                    context.surfaceController
                    as? TerminalSurface else {
                return
            }
            surface.recordPerformedFontSizeAction(
                action: action,
                previousRuntimePoints:
                    previousRuntimePoints,
                currentRuntimePoints:
                    currentRuntimePoints,
                previousIsAdjusted:
                    previousIsAdjusted,
                currentIsAdjusted:
                    currentIsAdjusted
            )
        }
    }

extension TerminalSurface {
    @MainActor
    func installFontSizeActionObservation(
        on runtimeSurface: ghostty_surface_t,
        callbackContext:
            Unmanaged<GhosttySurfaceCallbackContext>
    ) {
        precondition(
            ghostty_surface_set_font_size_action_callback(
                runtimeSurface,
                terminalGhosttyFontSizeActionCallback,
                callbackContext.toOpaque()
            ),
            "Each Ghostty surface installs one font action callback"
        )
    }

    @MainActor
    fileprivate func recordPerformedFontSizeAction(
        action: ghostty_font_size_action_e,
        previousRuntimePoints: Float32,
        currentRuntimePoints: Float32,
        previousIsAdjusted: Bool,
        currentIsAdjusted: Bool
    ) {
        guard fontSizeActionObservationSuppressionDepth == 0,
              previousRuntimePoints.isFinite,
              currentRuntimePoints.isFinite,
              previousRuntimePoints > 0,
              currentRuntimePoints > 0,
              var reloadState =
                pendingFontSizeConfigurationReloadState else {
            return
        }
        switch action {
        case GHOSTTY_FONT_SIZE_ACTION_INCREASE,
             GHOSTTY_FONT_SIZE_ACTION_DECREASE:
            reloadState.recordRelativeFontInput(
                previousRuntimePoints:
                    previousRuntimePoints,
                currentRuntimePoints:
                    currentRuntimePoints,
                previousIsAdjusted:
                    previousIsAdjusted,
                currentIsAdjusted:
                    currentIsAdjusted
            )
        case GHOSTTY_FONT_SIZE_ACTION_RESET:
            reloadState.recordResetFontInput()
        case GHOSTTY_FONT_SIZE_ACTION_SET:
            reloadState.recordAbsoluteFontInput(
                currentRuntimePoints:
                    currentRuntimePoints,
                currentIsAdjusted:
                    currentIsAdjusted
            )
        default:
            return
        }
        pendingFontSizeConfigurationReloadState =
            reloadState
    }
}
