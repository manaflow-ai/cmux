import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextUpdater

/// Shows "Restart cmux-tui to use new features" as a toast on the active window, asks the confirm
/// on its button, runs the restart and reports the result (plans/cmux-next/server-updates-DESIGN.md).
/// It never restarts on its own: skew only shows the toast.
@MainActor
final class ServerUpdatePresenter {
    let servers: ServerUpdateCoordinator
    private let daemon: DaemonService
    private let activeWindow: @MainActor () -> NSWindow?
    private var shown: [String: CmuxToastHandle] = [:]
    /// Notices whose confirm or restart is running: their toast does not show again meanwhile.
    private var busy: Set<String> = []
    private var observers: [Task<Void, Never>] = []

    init(daemon: DaemonService, defaults: UserDefaults, activeWindow: @escaping @MainActor () -> NSWindow?) {
        self.daemon = daemon
        self.activeWindow = activeWindow
        servers = ServerUpdateCoordinator(restarter: AppServerRestarter(daemon: daemon),
                                          snoozes: ServerUpdateSnoozeStore(defaults: defaults))
    }

    /// Follows the daemon's handshakes and the notices until the app quits.
    func start() {
        guard observers.isEmpty else { return }
        let daemon = daemon
        let servers = servers
        observers.append(Task { [weak self] in
            for await identity in ObservationStream({ daemon.identity }) {
                guard let identity else { continue }
                servers.report(ServerHandshake(daemon: identity, host: .local),
                               appCapabilities: ServerHandshake.appCmuxTUICapabilities, bundledBuild: nil)
                self?.sync()
            }
        })
        observers.append(Task { [weak self] in
            for await _ in ObservationStream({ servers.notices }) { self?.sync() }
        })
    }

    /// Shows a toast for each notice not shown yet; ends toasts whose notice went away.
    func sync() {
        let notices = servers.notices
        let ids = Set(notices.map(\.id))
        for (id, handle) in shown where !ids.contains(id) {
            shown[id] = nil
            handle.dismiss()
        }
        guard let window = activeWindow() else { return }
        for notice in notices where shown[notice.id] == nil && !busy.contains(notice.id) {
            show(notice, in: window)
        }
    }

    private func show(_ notice: ServerUpdateNotice, in window: NSWindow) {
        let toast = CmuxToast(id: "server-update.\(notice.id)", message: notice.toastMessage,
                              action: CmuxToast.Action(title: notice.restartButtonTitle), duration: CmuxToast.untilClosed)
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        shown[notice.id] = handle
        handle.onAction = { [weak self] in self?.confirm(notice, in: window) }
        handle.onDismiss = { [weak self, weak handle] reason in
            guard let self, let handle, self.shown[notice.id] === handle else { return }
            self.shown[notice.id] = nil
            // The close button snoozes this server build; a replaced or action-ended toast does not.
            if reason == .closed { self.servers.snooze(notice) }
        }
    }

    private func confirm(_ notice: ServerUpdateNotice, in window: NSWindow) {
        busy.insert(notice.id)
        _ = CmuxDialogCenter.shared.present(notice.confirmSpec, in: .window(window)) { [weak self] answer in
            guard let self else { return }
            guard answer.button == "restart" else {
                self.busy.remove(notice.id)
                self.sync()
                return
            }
            Task { @MainActor in
                let outcome = await self.servers.restart(notice)
                self.busy.remove(notice.id)
                let result = CmuxToast(id: "server-update.result.\(notice.kind.rawValue)",
                                       message: outcome.message(serverLabel: notice.serverLabel))
                if let window = self.activeWindow() { CmuxToastCenter.shared.show(result, in: window) }
                self.sync()
            }
        }
    }
}
