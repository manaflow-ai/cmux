import AppKit
import CmuxCloud
import CmuxSettings
import CmuxSurfaceCatalogModel
import Observation
import SwiftUI

/// Shows the "Start your first cloud agent" tour on the main window and binds
/// its model to the paths every other Cloud entrypoint uses:
///
/// - keys: Cloud Secrets names (``CloudSecretsService``) and the team's
///   CodeRouter accounts (the Cloud panel's ``CoderouterAccountStore``);
/// - machine: a fleet read for a ready machine, else the shared
///   ``MachineCreateCoordinator`` (the same pending row and create as
///   New Cloud Machine);
/// - Go: the bundled `cmux vm clone … --agent` through ``CloudVMActionLauncher``,
///   which opens and focuses the agent's terminal.
///
/// One tour at a time. Closing it keeps its model (and the machine it is
/// starting) until the agent runs, so reopening resumes instead of starting a
/// second machine.
@MainActor
final class CloudFirstRunPresenter {
    static let shared = CloudFirstRunPresenter()

    private var model: CloudFirstRunModel?
    private var sheetController: CloudSheetWindow?
    private var sheetWindow: NSWindow?
    private var hostWindow: NSWindow?
    private var secretsObserver: NSObjectProtocol?
    /// The last finished tour's timing line, for `debug.cloud_first_run.state`.
    private(set) var lastTimingLine: String?

    private init() {}

    var isPresented: Bool { sheetWindow != nil }
    var currentModel: CloudFirstRunModel? { model }

    func present(preferredWindow: NSWindow?) {
        if let sheetWindow {
            (hostWindow ?? sheetWindow).makeKeyAndOrderFront(nil)
            return
        }
        // Shown again by hand: an errand the person left for no longer brings it back.
        detour = nil
        let model = self.model ?? makeModel()
        self.model = model
        let actions = CloudFirstRunSheetActions(
            close: { [weak self] in self?.close() },
            addSubscription: { [weak self] agent in self?.addSubscription(agent, preferredWindow: preferredWindow) },
            openSecrets: { [weak self] in
                self?.leave(for: .secrets, preferredWindow: preferredWindow)
                CloudSecretsSheetPresenter.shared.present(
                    preferredWindow: preferredWindow,
                    onDismiss: {
                        // Let the secrets sheet finish closing before attaching again.
                        DispatchQueue.main.async { CloudFirstRunPresenter.shared.resumeAfterDetour(.secretsDismissed) }
                    }
                )
            }
        )
        let sheet = CloudSheetWindow(rootView: CloudFirstRunSheet(model: model, actions: actions))
        let window = sheet.window
        window.styleMask = [.titled]
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.title = String(localized: "cloud.firstRun.window.title", defaultValue: "Start Your First Cloud Agent")
        window.isReleasedWhenClosed = false
        sheetController = sheet
        sheetWindow = window
        observeKeys(model: model, preferredWindow: preferredWindow)
        model.start()

        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: preferredWindow)
        if let host, host.attachedSheet == nil {
            hostWindow = host
            sheet.beginSheet(on: host)
        } else {
            hostWindow = nil
            sheet.orderFrontFloating()
        }
    }

    /// Cancel, Esc, or `debug.cloud_first_run.interact {action: cancel}`.
    /// Before Go it cancels the tour, deleting the machine the tour started
    /// (``CloudFirstRunModel/cancel()``); after Go it only hides, and the run
    /// finishes and opens the agent.
    func close() {
        guard let model, !model.run.isBusy else {
            hide()
            return
        }
        model.cancel()
        detour = nil
        hide()
        self.model = nil
    }

    /// Where the person went from the sheet before Go, so the tour comes
    /// back by itself once that errand is done.
    enum Detour {
        /// Cloud Secrets: back when the sheet is dismissed.
        case secrets
        /// A subscription sign-in in a terminal: back once the key step is ready.
        case subscription
    }

    private var detour: Detour?
    private var detourWindow: NSWindow?

    /// Leaving the sheet for an errand counts as leaving before Go: a machine
    /// the tour started is cleaned up rather than left running unattended,
    /// and the machine step starts again when the tour comes back.
    func leave(for detour: Detour, preferredWindow: NSWindow?) {
        if let model, !model.run.isBusy { model.cancel() }
        hide()
        self.detour = detour
        detourWindow = preferredWindow
    }

    /// What may end a detour: only closing Cloud Secrets ends a secrets errand.
    enum DetourSignal {
        case secretsDismissed
        case accountsChanged
    }

    fileprivate func resumeAfterDetour(_ signal: DetourSignal) {
        guard let detour, sheetWindow == nil, let model else { return }
        switch (detour, signal) {
        case (.secrets, .secretsDismissed): break
        case (.subscription, .accountsChanged):
            guard model.keySource.isReady else { return }
        default: return
        }
        self.detour = nil
        present(preferredWindow: detourWindow)
    }

    /// Takes the sheet down and keeps the model (and its in-flight work).
    func hide() {
        if let secretsObserver { NotificationCenter.default.removeObserver(secretsObserver) }
        secretsObserver = nil
        guard let window = sheetWindow else { return }
        if let host = hostWindow, host.attachedSheet === window {
            host.endSheet(window)
        }
        window.orderOut(nil)
        sheetController = nil
        sheetWindow = nil
        hostWindow = nil
    }

    // MARK: Model

    private func makeModel() -> CloudFirstRunModel {
        let model = CloudFirstRunModel(backend: Self.liveBackend())
        model.onStarted = { [weak self] _ in
            guard let self else { return }
            // The agent's terminal is open and focused behind the sheet.
            self.hide()
            self.model = nil
        }
        return model
    }

    /// Re-resolves the key step when the vault or the team's accounts change.
    private func observeKeys(model: CloudFirstRunModel, preferredWindow: NSWindow?) {
        let service = CloudSecretsService.shared
        secretsObserver = NotificationCenter.default.addObserver(
            forName: CloudSecretsService.didChangeNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated { model?.refreshKeys() }
        }
        Task { [weak model] in
            await service.reload()
            model?.refreshKeys()
        }
        if let store = Self.coderouterStore() {
            // Ask the Cloud panel's store for a fresh read, then follow it.
            store.refreshRequest &+= 1
            Self.followAccounts(store: store, model: model)
        }
    }

    private static func followAccounts(store: CoderouterAccountStore, model: CloudFirstRunModel) {
        withObservationTracking {
            _ = store.state.accounts
        } onChange: { [weak store, weak model] in
            Task { @MainActor in
                guard let store, let model else { return }
                model.refreshKeys()
                CloudFirstRunPresenter.shared.resumeAfterDetour(.accountsChanged)
                followAccounts(store: store, model: model)
            }
        }
    }

    private static func coderouterStore() -> CoderouterAccountStore? {
        AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)?.coderouterAccountStore
    }

    // MARK: Subscription

    /// The agent's subscription goes onto the team's model router with the
    /// same command the Cloud panel's New Account row runs. The tour hides so
    /// the terminal is usable, and resumes when reopened.
    private func addSubscription(_ agent: CloudFirstRunAgent, preferredWindow: NSWindow?) {
        leave(for: .subscription, preferredWindow: preferredWindow)
        let provider = CoderouterProvider(id: agent.coderouterProviderID)
        let store = Self.coderouterStore()
        let destination = store.flatMap { $0.state.destination(for: $0.state.scope) }
        let cmuxExecutable = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/cmux").path
        let command = destination.map {
            provider.addCommand(for: $0.organizationID, scope: $0.teamScope, cmuxExecutable: cmuxExecutable)
        } ?? provider.addCommand(for: nil, cmuxExecutable: cmuxExecutable)
        let coordinator = CoderouterSetupWorkspaceCoordinator(
            managerSource: {
                AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: preferredWindow)
            },
            provider: provider,
            initialTerminalCommand: command
        )
        guard case .existing(let workspace, _)? = coordinator.resolveDestination() else { return }
        Task {
            _ = try? await TerminalController.surfaceNewTerminal(
                machine: .local,
                command: ["sh", "-lc", command],
                cwd: nil,
                name: "CodeRouter",
                remoteWorkspaceID: nil,
                destination: .workspace(id: workspace.id, placement: .split),
                focus: true
            )
        }
    }

    // MARK: Live backend

    static func liveBackend() -> CloudFirstRunModel.Backend {
        CloudFirstRunModel.Backend(
            vaultNames: { projectKey in
                Set(CloudSecretsService.shared.records.filter { record in
                    switch record.scope {
                    case .all: return true
                    case .project(let key): return key == projectKey
                    case .machine: return false
                    }
                }.map(\.name))
            },
            activeTeamProviders: {
                let accounts = coderouterStore()?.state.accounts ?? []
                return Set(accounts.filter { ($0.state ?? "active") == "active" }.map(\.provider.id))
            },
            findReadyMachine: {
                await readyMachine(id: nil)
            },
            createMachine: { finished in
                startMachineCreate(finished: finished)
            },
            saveKey: { name, value in
                let input = CloudSecretInput(name: name, value: value)
                try input.validate()
                // The clone syncs the machine it runs on; other machines get
                // the key on their next sync.
                _ = try await CloudSecretsService.shared.set([input], scope: .all, source: .manual, sync: false)
            },
            runClone: { arguments, onOutput, finished in
                let socketPath = TerminalController.shared.activeSocketPath(
                    preferredPath: SocketControlSettings.socketPath()
                )
                return CloudVMActionLauncher.shared.start(
                    socketPath: socketPath,
                    preferredWindow: NSApp.mainWindow,
                    arguments: arguments,
                    presentsFailureAlert: false,
                    onOutput: { chunk in onOutput(chunk) },
                    onCompletion: { completion in
                        MainActor.assumeIsolated {
                            finished(completion.wasCancelled ? 130 : completion.terminationStatus, completion.output)
                        }
                    }
                )
            },
            cancelCreate: {
                guard let operationID = inFlightCreateOperationID else { return }
                MachineCreateCoordinator.shared.cancel(operationID)
            },
            deleteMachine: { machineID in
                // The app's shared delete: `vm rm` through the socket, with the
                // delete coordinator's cleanup (Cloud Secrets forgets the machine).
                CloudVMActionLauncher.shared.destroyMachineBestEffort(machineID)
            },
            log: { line in
#if DEBUG
                cmuxDebugLog(line)
#endif
                CloudFirstRunPresenter.shared.lastTimingLine = line
            }
        )
    }

    /// A ready machine from a fresh fleet read: `id` when given, else the
    /// newest ready one that is not being deleted.
    private static func readyMachine(id: String?) async -> CloudFirstRunMachine? {
        guard let client = VMClient.shared, let page = try? await client.listPage() else { return nil }
        let hidden = MachineDeleteCoordinator.shared.hiddenMachineIDs
        let rows = page.vms
            .filter { id == nil || $0.id == id }
            .map { (id: $0.id, status: $0.status, name: $0.preferredName, createdAt: $0.createdAt) }
        return CloudFirstRunMachine.reusable(from: rows, hiddenIDs: hidden)
    }

    /// The create the tour started, while it runs: what Cancel cancels.
    private static var inFlightCreateOperationID: UUID?

    /// A default machine through the shared create coordinator, so the
    /// Machines panel shows the same pending row New Cloud Machine shows.
    private static func startMachineCreate(
        finished: @escaping @MainActor (Result<CloudFirstRunMachine, CloudFirstRunFailure>) -> Void
    ) -> Bool {
        let kind = NewMachineModel.machineKind
        let request = MachineCreateRequest(
            mode: .newMachine,
            kind: kind,
            name: nil,
            arguments: ["vm", "new", kind.cliFlag, "--focus", "false"]
        )
        return MachineCreateCoordinator.shared.start(request, cancellableLaunch: { operationID, arguments, progress, completion in
            inFlightCreateOperationID = operationID
            var cancellation: CloudVMActionLauncher.CancellationHandle?
            let didStart = MachineRowActions.openNewMachine(
                arguments: arguments,
                operationID: operationID,
                onOutput: progress,
                onCompletion: { result in
                    MainActor.assumeIsolated {
                        if inFlightCreateOperationID == operationID { inFlightCreateOperationID = nil }
                        completion(result)
                        machineCreateFinished(result, finished: finished)
                    }
                },
                onCancellationReady: { cancellation = $0 }
            )
            return didStart ? cancellation : nil
        })
    }

    private static func machineCreateFinished(
        _ result: CloudVMActionLauncher.Completion,
        finished: @escaping @MainActor (Result<CloudFirstRunMachine, CloudFirstRunFailure>) -> Void
    ) {
        guard result.succeeded, !result.wasCancelled else {
            // A cancel that raced the provider: never leave its machine behind.
            if result.wasCancelled, let id = result.machineId {
                CloudVMActionLauncher.shared.destroyMachineBestEffort(id)
            }
            finished(.failure(machineFailure(result)))
            return
        }
        let id = result.machineId
        Task { @MainActor in
            if let machine = await readyMachine(id: id) {
                finished(.success(machine))
            } else if let id {
                finished(.success(CloudFirstRunMachine(
                    id: id,
                    name: String(localized: "cloud.firstRun.machine.new", defaultValue: "New machine")
                )))
            } else {
                finished(.failure(machineFailure(result)))
            }
        }
    }

    private static func machineFailure(_ result: CloudVMActionLauncher.Completion) -> CloudFirstRunFailure {
        if result.wasCancelled {
            return CloudFirstRunFailure(
                reason: String(localized: "cloud.firstRun.machine.cancelled", defaultValue: "The new machine was cancelled."),
                recovery: .retryMachine
            )
        }
        if result.refusalCode == CloudPlanRefusal.activeLimitExceededCode {
            return CloudFirstRunFailure(
                reason: String(
                    localized: "cloud.firstRun.machine.limit",
                    defaultValue: "Your plan\u{2019}s running-machine limit is reached. Pause a machine, then try again."
                ),
                recovery: .retryMachine
            )
        }
        let headline = result.output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return CloudFirstRunFailure(
            reason: headline.map { String($0.prefix(200)) } ?? String(
                localized: "cloud.firstRun.machine.couldNotStart",
                defaultValue: "cmux couldn\u{2019}t start a machine. Check that you\u{2019}re signed in."
            ),
            recovery: .retryMachine
        )
    }
}
