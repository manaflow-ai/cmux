import Foundation
import Bonsplit
import CmuxPanes
import CmuxTerminal
import CmuxTerminalCore

extension GhosttyApp {
    /// Converts Ghostty's split direction into the pane model's direction.
    func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    /// Converts Ghostty's focus direction into the pane navigator's direction.
    func focusDirection(from direction: ghostty_action_goto_split_e) -> NavigationDirection? {
        switch direction {
        // Bonsplit has directional navigation rather than cycle-based navigation.
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .left
        case GHOSTTY_GOTO_SPLIT_NEXT: return .right
        case GHOSTTY_GOTO_SPLIT_UP: return .up
        case GHOSTTY_GOTO_SPLIT_DOWN: return .down
        case GHOSTTY_GOTO_SPLIT_LEFT: return .left
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    /// Converts Ghostty's resize direction into the pane model's direction.
    func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> ResizeDirection? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    /// Recovers the surface callback context retained by Ghostty userdata.
    static func callbackContext(
        from userdata: UnsafeMutableRawPointer?
    ) -> GhosttySurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Recovers the runtime app retained by Ghostty userdata.
    static func runtimeApp(from userdata: UnsafeMutableRawPointer?) -> GhosttyApp? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Completes a configuration reload only for its original surface generation.
    func completeMobileViewportFontFitConfigurationReload(
        callbackContext: GhosttySurfaceCallbackContext,
        runtimeSurface: ghostty_surface_t,
        configuredFontPointSize: Float?
    ) {
        let reloadCompletion = performOnMain {
            guard callbackContext.isCurrentOrigin(runtimeSurface: runtimeSurface),
                  let terminalSurface = callbackContext.terminalSurface,
                  let generation = terminalSurface.pendingMobileViewportFontFitReloadGeneration else {
                return nil as (surface: TerminalSurface, generation: UInt64)?
            }
            return (terminalSurface, generation)
        }
        Task { @MainActor in
            guard callbackContext.isCurrentOrigin(runtimeSurface: runtimeSurface),
                  let reloadCompletion else { return }
            reloadCompletion.surface.completeMobileViewportFontFitConfigurationReload(
                configuredFontPointSize: configuredFontPointSize,
                reloadGeneration: reloadCompletion.generation,
                reason: "surface.configChange"
            )
        }
    }
}
