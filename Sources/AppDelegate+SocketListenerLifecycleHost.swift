import CmuxControlSocket
import CmuxSettings
import Foundation

/// The per-window tab manager is the start target a control-socket listener
/// binds to. The marker lets `SocketListenerLifecycleCoordinator` thread a
/// caller-supplied or host-resolved tab manager through the start path without
/// naming this app-target type.
extension TabManager: SocketListenerStartTarget {}

/// `AppDelegate`'s conformance to the control-socket listener lifecycle seam.
///
/// `SocketListenerLifecycleCoordinator` owns the policy; these witnesses perform
/// the irreducible live-state work that cannot leave the app target: driving the
/// live `TerminalController` socket server, probing the socket transport's
/// reclaim lock, resolving the active main-window tab manager for a restart, and
/// recording Sentry breadcrumbs.
extension AppDelegate: SocketListenerLifecycleHost {
    nonisolated func startupPathCanBeReclaimed(_ path: String) -> Bool {
        socketTransport.pathCanBeReclaimedForStartup(path)
    }

    func reserveStartupSocketPath(_ path: String) {
        terminalControl.reserveStartupSocketPath(path)
    }

    // `nonisolated`: cannot read the `@MainActor` `terminalControl` instance
    // property, so these two witnesses keep the transitional `shared` accessor
    // (it resolves to the same composition-root-owned instance) until the seam
    // exposes a nonisolated handle.
    nonisolated func activeSocketPath(preferredPath: String) -> String {
        TerminalController.shared.activeSocketPath(preferredPath: preferredPath)
    }

    nonisolated func listenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
        TerminalController.shared.socketListenerHealth(expectedSocketPath: expectedSocketPath)
    }

    func resolveRestartTarget() -> (any SocketListenerStartTarget)? {
        tabManager
            ?? preferredRegisteredMainWindowContext()?.tabManager
            ?? registeredMainWindows.first?.tabManager
    }

    func startListener(
        target: any SocketListenerStartTarget,
        socketPath: String,
        mode: SocketControlMode
    ) {
        guard let manager = target as? TabManager else { return }
        terminalControl.start(tabManager: manager, socketPath: socketPath, accessMode: mode)
    }

    func stopListener() {
        terminalControl.stop()
    }

    func recordBreadcrumb(_ message: String, data: [String: String]) {
        sentryBreadcrumb(message, category: "socket", data: data)
    }
}
