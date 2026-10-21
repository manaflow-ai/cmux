import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextRemote
import CmuxNextUpdater

/// Update cmux Components… (palette, CLI `settings update-components`, MCP): one place that says
/// whether this Mac runs what the app bundles (plans/cmux-next/server-updates-DESIGN.md section 7)
/// and, on Update All, runs each part's own update path: Update Agent CLIs, the app's install
/// (which waits for busy agents; the new app hands both daemons off as it starts), else the
/// acpmux handoff that keeps agents and the cmux-tui restart that keeps terminals. The dialog is
/// the confirm; nothing runs without it. Nothing here polls: each part is read once per open.
@MainActor
final class ComponentUpdates {
    private weak var services: AppServices?
    /// A read or the dialog is open: another ask while it is does nothing.
    private var open = false

    init(services: AppServices) {
        self.services = services
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let updates = ComponentUpdates(services: context.services)
        registry.bind("palette.updateComponents", run: { _ in updates.present() })
    }

    func present() {
        guard !open, let services else { return }
        open = true
        Task { @MainActor [weak self] in
            let status = await Self.read(services)
            guard let self, let window = services.windows.active?.window else {
                self?.open = false
                return
            }
            _ = CmuxDialogCenter.shared.present(status.dialogSpec, in: .window(window)) { [weak self] answer in
                self?.open = false
                guard answer.button == "update" else { return }
                Task { @MainActor in await self?.updateAll(status) }
            }
        }
    }

    /// Each part once: the updater's phase, the local daemon's handshake and the bundled cmux-tui
    /// stamp, and acpmux's status and cached harness inventory (never a fresh health check).
    private static func read(_ services: AppServices) async -> ComponentStatus {
        var bundledTUI: String?
        if let bin = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux") { bundledTUI = await BundledCmuxTUI.commit(binary: bin) }
        let identity = services.daemon.identity
        let cmuxTUI = ComponentStatus.Server(isRunning: identity != nil, running: identity?.buildCommit, bundled: bundledTUI, keepsWork: true)
        let environment = QuitAgents.environment(services)
        let acpmux = await environment?.buildCheck()
        let inventory = try? await environment?.harnessInventory()
        return ComponentStatus(app: app(services.updater.indicatorPhase), appVersion: services.updater.identity.shortVersion,
                               cmuxTUI: cmuxTUI, acpmux: environment == nil ? nil : server(acpmux),
                               outdatedAgentCLIs: inventory.map { $0.harnesses.filter(\.outdated).map(\.id) })
    }

    /// No daemon of this app answering (none, or another home's) is a server that does not run.
    private static func server(_ check: AcpmuxBuildCheck?) -> ComponentStatus.Server {
        ComponentStatus.Server(isRunning: check != nil, running: check?.running, bundled: check?.bundled,
                               keepsWork: check?.agentHosts ?? false)
    }

    private static func app(_ phase: UpdateIndicatorPhase) -> ComponentStatus.App {
        switch phase {
        case .available(let version): .available(version)
        case .ready(let version): .ready(version)
        default: .current
        }
    }

    /// The parts the dialog listed, in its order; a result toast says what each did.
    private func updateAll(_ status: ComponentStatus) async {
        guard let services else { return }
        var results: [String] = []
        if status.updatesAgentCLIs, services.registry.perform("agent.harness.updateAll", invocation: ActionInvocation(origin: .user)) {
            results.append(ComponentStatus.agentCLIsStarted)
        }
        if status.installsApp {
            do {
                try services.updater.installAvailableUpdate()
                results.append(ComponentStatus.appInstalling)
            } catch {
                results.append(ComponentStatus.appFailed(String(describing: error)))
            }
        }
        if status.restartsAcpmux, let host = services.agentTabs.host as? AcpmuxHost {
            do {
                try await host.updateToBundledBuild()
                let check = await QuitAgents.environment(services)?.buildCheck()
                results.append(ComponentStatus.acpmuxUpdated(check.map { Self.server($0) }))
            } catch {
                results.append(ComponentStatus.acpmuxFailed)
            }
        }
        if status.restartsCmuxTUI, let line = await services.serverUpdates.restartLocalCmuxTUI() {
            results.append(line)
        }
        guard !results.isEmpty, let window = services.windows.active?.window else { return }
        let toast = CmuxToast(id: "components.update.result", message: results.joined(separator: " "), duration: .seconds(12))
        CmuxToastCenter.shared.show(toast, in: window)
    }
}
