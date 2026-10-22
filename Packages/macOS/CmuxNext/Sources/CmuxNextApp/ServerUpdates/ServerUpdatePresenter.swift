import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonRecovery
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextUpdater

/// Shows "Restart cmux-tui to use new features" as a toast on the active window, asks the confirm
/// on its button, runs the restart and reports the result (plans/cmux-next/server-updates-DESIGN.md).
/// A stale local cmux-tui (another build, or missing capabilities) restarts by itself at a quiet
/// moment instead (``QuietDaemonUpdate``, rule 2: the handoff keeps every terminal). Its toast shows
/// when no such restart waits (refused, impossible with an external binary, turned off), when no
/// quiet moment came for a long time, and with a failure toast when the restarted cmux-tui did not
/// come back on the bundled build.
@MainActor
final class ServerUpdatePresenter {
    let servers: ServerUpdateCoordinator
    let quietUpdate: QuietDaemonUpdate
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
        quietUpdate = QuietDaemonUpdate(daemon: daemon) { DaemonTunables.restartStaleCmuxTUIWhenQuiet.value }
        daemon.recovery.restartsUnresponsiveOwner = { DaemonTunables.restartUnresponsiveCmuxTUI.value }
    }

    /// Follows the daemon's handshakes and the notices until the app quits, and binds
    /// Restart cmux-tui… (palette, `cmux settings restart-server`, MCP) to the same confirm.
    func start(registry: ActionRegistry) {
        guard observers.isEmpty else { return }
        registry.bind("palette.restartServer", run: { [weak self] _ in self?.confirmRestart() })
        let daemon = daemon
        let servers = servers
        let quietUpdate = quietUpdate
        observers.append(Task { [weak self] in
            for await identity in ObservationStream({ daemon.identity }) {
                guard let identity else { continue }
                let capabilities = ServerHandshake.appCmuxTUICapabilities
                // Every handshake, the first one and each reconnect's, with the bundled build read again.
                let bundled = await daemon.bundledBuild()
                quietUpdate.consider(identity, bundledBuild: bundled, appCapabilities: capabilities)
                servers.report(ServerHandshake(daemon: identity, host: .local), appCapabilities: capabilities, bundledBuild: bundled)
                self?.sync()
            }
        })
        observers.append(Task { [weak self] in
            for await _ in ObservationStream({ _ = servers.notices; _ = quietUpdate.suppressesNotice }) { self?.sync() }
        })
        observers.append(Task { [weak self] in
            for await failure in ObservationStream({ quietUpdate.healthFailure }) {
                guard let failure else { continue }
                self?.showResult(.failed(failure), kind: .cmuxTUI, label: ServerKind.cmuxTUI.displayName)
            }
        })
    }

    /// The notices to show: all but the local cmux-tui's while its quiet restart waits.
    private var shownNotices: [ServerUpdateNotice] {
        guard quietUpdate.suppressesNotice else { return servers.notices }
        return servers.notices.filter { $0.kind != .cmuxTUI || $0.host != .local }
    }

    /// The toast after a restart, on the active window.
    private func showResult(_ outcome: ServerRestartOutcome, kind: ServerKind, label: String) {
        let result = CmuxToast(id: "server-update.result.\(kind.rawValue)", message: outcome.message(serverLabel: label))
        if let window = activeWindow() { CmuxToastCenter.shared.show(result, in: window) }
    }

    /// Shows a toast for each notice not shown yet; ends toasts whose notice went away.
    func sync() {
        let notices = shownNotices
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

    /// Restart cmux-tui… from the palette, CLI or MCP: the same confirm as the toast's button,
    /// for the current notice or, with none, a plain restart.
    func confirmRestart() {
        guard let window = activeWindow() else { return }
        let notice = servers.notices.first { $0.kind == .cmuxTUI && $0.host == .local }
            ?? ServerUpdateNotice(kind: .cmuxTUI, host: .local,
                                  serverBuild: servers.handshake(.cmuxTUI, host: .local)?.build,
                                  missingCapabilities: [], gainedFeatures: [],
                                  impact: ServerRestartImpact(kind: .cmuxTUI, keepsWork: true))
        shown[notice.id]?.dismiss()
        confirm(notice, in: window)
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
                self.showResult(outcome, kind: notice.kind, label: notice.serverLabel)
                self.sync()
            }
        }
    }
}
