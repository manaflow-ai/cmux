import AppKit
import CmuxControlSocket
import Foundation

/// The app-focus-domain witnesses are the byte-faithful bodies of the former
/// `v2AppFocusOverride` / `v2AppSimulateActive` dispatchers, minus the per-read
/// `v2MainSync` hop: the coordinator already runs on the main actor inside the
/// socket-command policy scope, so each hop would re-apply the identical
/// thread-local focus-allowance stack — a no-op.
extension TerminalController: ControlAppFocusContext {
    func controlSetAppFocusOverride(_ focused: Bool?) {
        AppFocusState.overrideIsFocused = focused
    }

    func controlSimulateAppActive() {
        AppDelegate.shared?.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification)
        )
    }
}
