import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextUpdater
import CmuxNextWakeups

/// Shows "Restart cmux-tui to use new features" as a toast on the active window, asks the confirm
/// on its button, runs the restart and reports the result (plans/cmux-next/server-updates-DESIGN.md).
/// It never restarts on its own: skew only shows the toast.
@MainActor
final class ServerUpdatePresenter {
    let servers: ServerUpdateCoordinator
    /// The socket and Tailscale address Settings > Server shows beside the handshakes.
    let facts = ServerSettingsFacts()
    private let tailnet: ServerTailnetSource
    private let daemon: DaemonService
    private let activeWindow: @MainActor () -> NSWindow?
    private var shown: [String: CmuxToastHandle] = [:]
    /// Notices whose confirm or restart is running: their toast does not show again meanwhile.
    private var busy: Set<String> = []
    /// The handshake and notice follows (``ServiceObservation``s), from ``start()`` on.
    private var observers: [AnyObject] = []
    /// The app's main-thread scheduler: the follows' flushes and the main part of each async step.
    private let mainWork: MainWorkScheduler
    /// Where the async steps (the facts' reads, a restart) are awaited, off main.
    private let work: BackgroundWork

    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler.
    ///   - work: The app's one ``BackgroundWork``.
    init(daemon: DaemonService, defaults: UserDefaults, mainWork: MainWorkScheduler, work: BackgroundWork,
         tailnet: ServerTailnetSource = .app(), activeWindow: @escaping @MainActor () -> NSWindow?) {
        self.daemon = daemon
        self.mainWork = mainWork
        self.work = work
        self.tailnet = tailnet
        self.activeWindow = activeWindow
        servers = ServerUpdateCoordinator(restarter: AppServerRestarter(daemon: daemon),
                                          snoozes: ServerUpdateSnoozeStore(defaults: defaults))
    }

    /// Binds Restart cmux-tui… (palette, `cmux settings restart-server`, MCP) to the toast's
    /// confirm, in `AppServices.init`: the action works before the observers start.
    func bind(registry: ActionRegistry) {
        registry.bind("palette.restartServer", run: { [weak self] _ in self?.confirmRestart() })
    }

    /// Follows the daemon's handshakes and the notices until the app quits (the
    /// `ServerUpdates.start` launch post). Once.
    func start() {
        guard observers.isEmpty else { return }
        let daemon = daemon
        let servers = servers
        // Each handshake reports the server and re-reads Settings > Server's facts: model writes nobody waits on.
        observers.append(ServiceObservation(.background, owner: "ServerUpdates.handshake", on: mainWork) {
            daemon.identity
        } apply: { [weak self] identity in
            guard let identity else { return }
            servers.report(ServerHandshake(daemon: identity, host: .local),
                           appCapabilities: ServerHandshake.appCmuxTUICapabilities, bundledBuild: nil)
            self?.sync()
            self?.refreshFacts()
        })
        // A notice's toast shows on the active window: visible work no input of the person's caused.
        observers.append(ServiceObservation(.visible, owner: "ServerUpdates.notices", on: mainWork) {
            servers.notices
        } apply: { [weak self] _ in
            self?.sync()
        })
    }

    /// Settings > Server: a row per server heard from, with the socket and tailnet address.
    var settingsReport: ServerSettingsReport {
        servers.settingsReport(socketPath: facts.socketPath, tailnetAddress: facts.tailnetAddress)
    }

    /// The host lists' `server` (reading it registers the Observation dependencies the page watches).
    var settingsPageJSON: CmuxNextSettings.JSONValue { ServerSettingsPageJSON(report: settingsReport).json }

    /// Re-reads the socket and the Tailscale address (after a handshake): read off main, stored in one
    /// background task.
    private func refreshFacts() {
        let connection = daemon.connection, tailnet = tailnet, facts = facts, mainWork = mainWork
        // task-owner: one facts read per handshake; a later handshake's read overwrites it
        work.task(.bestEffort) {
            let socket = await connection?.endpoint?.socketPath
            let address = await tailnet.address()
            mainWork.postFromAnyThread(.background, owner: "ServerUpdates.facts") {
                facts.socketPath = socket
                facts.tailnetAddress = address
            }
        }
    }

    /// Restart… on a Settings row: the same confirm as the toast. Only the local cmux-tui can
    /// restart from here yet (`AppServerRestarter`).
    func confirmRestart(kind: ServerKind, host: ServerHost) {
        guard kind == .cmuxTUI, host == .local else { return }
        confirmRestart()
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
            let servers = self.servers, mainWork = self.mainWork
            // task-owner: one restart the person confirmed. R-hop: awaited off main at the priority of the
            // person's click; its result is one userBlocking task (the rest of the person's action).
            self.work.task(.userBlocking) { [weak self] in
                let outcome = await servers.restart(notice)
                mainWork.postFromAnyThread(.userBlocking, owner: "ServerUpdates.restarted") { [weak self] in
                    self?.restarted(notice, outcome)
                }
            }
        }
    }

    /// A confirmed restart ended: its toast says how, and the notices show again as they are now.
    private func restarted(_ notice: ServerUpdateNotice, _ outcome: ServerRestartOutcome) {
        busy.remove(notice.id)
        let result = CmuxToast(id: "server-update.result.\(notice.kind.rawValue)",
                               message: outcome.message(serverLabel: notice.serverLabel))
        if let window = activeWindow() { CmuxToastCenter.shared.show(result, in: window) }
        sync()
    }
}
