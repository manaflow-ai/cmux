import Foundation
import CmuxSettings

/// App-owned orchestrator for the socket-control server lifecycle.
///
/// Sequences the start/stop decision that the SwiftUI `cmuxApp` previously
/// inlined in `updateSocketController()`: it migrates the persisted raw mode,
/// resolves the effective access mode, then starts the composition-root
/// `TerminalController`'s control server bound to the active `TabManager` at the
/// active socket path, or stops it when the effective mode is `.off`.
///
/// The trigger stays in `cmuxApp` because it is SwiftUI-bound: the
/// `@AppStorage socketControlMode` value and its `.onChange` modifier live in the
/// App, which forwards the raw mode and the active `TabManager` to ``apply(rawMode:tabManager:)``.
/// The injected `AppDelegate` is the composition root that owns the
/// `TerminalController`; reading `appDelegate.terminalControl` per call preserves
/// the `lazy` first-use timing of that instance.
@MainActor
struct SocketControlCoordinator {
    private let appDelegate: AppDelegate

    /// - Parameter appDelegate: the composition root that owns the
    ///   `TerminalController` socket-control server.
    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    /// Apply `rawMode` to the socket-control server.
    ///
    /// Migrates the stored raw value, resolves the effective access mode, and
    /// either starts the control server bound to `tabManager` at the active
    /// socket path or stops it when the effective mode is `.off`. Byte-faithful
    /// to the former `cmuxApp.updateSocketController()`.
    func apply(rawMode: String, tabManager: TabManager) {
        // Use the composition-root-owned instance (de-singletonization stage
        // b72) rather than the transitional `TerminalController.shared` accessor.
        let terminalControl = appDelegate.terminalControl
        let mode = SocketControlSettings.effectiveMode(
            userMode: SocketControlSettings.migrateMode(rawMode)
        )
        if mode != .off {
            let socketPath = terminalControl.activeSocketPath(
                preferredPath: SocketControlSettings.socketPath()
            )
            terminalControl.start(
                tabManager: tabManager,
                socketPath: socketPath,
                accessMode: mode
            )
        } else {
            terminalControl.stop()
        }
    }
}
