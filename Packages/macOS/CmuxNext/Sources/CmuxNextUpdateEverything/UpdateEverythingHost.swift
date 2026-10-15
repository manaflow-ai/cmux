public import AppKit
public import CmuxNextActions
public import CmuxNextDaemonService
public import CmuxNextUpdater
import Foundation

/// What Update Everything needs from the App, injected at startup so the App's services stay out of
/// this module (cx-1mbnu): its machines, the SSH and Cloud update paths and the active window.
@MainActor
public struct UpdateEverythingHost: Sendable {
    /// This Mac's daemon.
    public var local: @MainActor @Sendable () -> DaemonService
    /// Every connected SSH and Cloud machine.
    public var remotes: @MainActor @Sendable () -> [UpdateEverythingDaemon.Target]
    /// A machine's daemon by id.
    public var daemon: @MainActor @Sendable (String) -> DaemonService?
    /// Installs this app's cmux-tui on the SSH machine with this id (`SSHService.install`).
    public var installSSH: @MainActor @Sendable (String) async throws -> Void
    /// Updates the Cloud machine whose daemon listens at this socket to this app's bundled build
    /// (`cmux link machine update --to-bundled`); true when it changed the build.
    public var updateCloud: @MainActor @Sendable (String) async throws -> Bool
    public var updater: UpdaterService
    /// The window the confirmation and toasts show in.
    public var window: @MainActor @Sendable () -> NSWindow?
    /// Where the run notes what the relaunched app must finish.
    public var journal: URL

    public init(local: @escaping @MainActor @Sendable () -> DaemonService,
                remotes: @escaping @MainActor @Sendable () -> [UpdateEverythingDaemon.Target],
                daemon: @escaping @MainActor @Sendable (String) -> DaemonService?,
                installSSH: @escaping @MainActor @Sendable (String) async throws -> Void,
                updateCloud: @escaping @MainActor @Sendable (String) async throws -> Bool, updater: UpdaterService,
                window: @escaping @MainActor @Sendable () -> NSWindow?, journal: URL) {
        self.local = local
        self.remotes = remotes
        self.daemon = daemon
        self.installSSH = installSSH
        self.updateCloud = updateCloud
        self.updater = updater
        self.window = window
        self.journal = journal
    }
}

/// Update Everything's action: the palette and app menu action reads what every machine would
/// update, asks once, then updates the machines and the app last. A run the app relaunched in the
/// middle of finishes at the next launch, once the machines reconnect.
@MainActor
public enum UpdateEverything {
    public static let actionID: ActionID = "updates.updateEverything"

    /// Binds the action and starts the launch's one check for a run to finish.
    public static func bind(into registry: ActionRegistry, host: UpdateEverythingHost) {
        let steps = UpdateEverythingHostSteps(host)
        let runner = UpdateEverythingRunner(journal: UpdateEverythingJournal(url: host.journal))
        registry.bind(actionID, invoke: { [weak registry] _ in
            guard runner.claim() else {
                registry?.refuse(UpdateEverythingRunner.alreadyRunning)
                return
            }
            // task-owner: one confirmation and its run; ends with the run's result toast
            Task { @MainActor in
                defer { runner.release() }
                await UpdateEverythingDaemon.ask(plan: { await steps.plan() }, runner: runner, steps: steps, window: host.window)
            }
        })
        // task-owner: the launch's one check for a run the app relaunched in; ends with that run
        Task { @MainActor in
            guard let outcomes = await runner.finishAfterRelaunch(plan: { await steps.plan(waitingFor: $0) }, steps: steps) else { return }
            UpdateEverythingDaemon.report(outcomes, in: host.window())
        }
    }
}

/// The update paths over the host: Sparkle for the app, the host's SSH and Cloud updates for the
/// machines' cmux daemons, and each machine daemon's own agent CLI update.
@MainActor
final class UpdateEverythingHostSteps: UpdateEverythingSteps {
    private let host: UpdateEverythingHost

    init(_ host: UpdateEverythingHost) {
        self.host = host
    }

    /// This Mac, then every connected SSH and Cloud machine.
    func plan() async -> UpdateEverythingPlan {
        await UpdateEverythingDaemon.plan([("local", UpdateEverythingMachine.thisMac, .local, host.local())] + host.remotes(), updater: host.updater)
    }

    /// ``plan()`` after a relaunch, once (bounded) the machines the run named are back and connected.
    func plan(waitingFor machineIDs: [String]) async -> UpdateEverythingPlan {
        let host = host
        _ = await UpdateEverythingDaemon.holds {
            host.local().connection != nil && machineIDs.allSatisfy { host.daemon($0)?.connection != nil }
        }
        return await plan()
    }

    func updateDaemon(on machine: UpdateEverythingMachine) async throws {
        guard machine.kind != .local else { return }
        guard let daemon = host.daemon(machine.id) else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
        let before = daemon.identity?.pid
        if machine.kind == .ssh {
            try await host.installSSH(machine.id)
        } else {
            guard let socket = await daemon.connection?.endpoint?.socketPath else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
            guard try await host.updateCloud(socket) else { return }
        }
        try await UpdateEverythingDaemon.waitForNewDaemon(daemon, replacing: before)
    }

    func outdatedAgents(on machine: UpdateEverythingMachine) async -> [UpdateEverythingChange] {
        await UpdateEverythingDaemon.outdatedAgents(host.daemon(machine.id))
    }

    func updateAgents(on machine: UpdateEverythingMachine, continueThreads: Bool) async throws -> String? {
        try await UpdateEverythingDaemon.updateAgents(host.daemon(machine.id), machine, continueThreads: continueThreads)
    }

    func installApp() throws {
        try host.updater.installAvailableUpdate()
    }
}
