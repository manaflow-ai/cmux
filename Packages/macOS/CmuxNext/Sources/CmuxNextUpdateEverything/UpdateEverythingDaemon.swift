public import AppKit
import CmuxNextCompat
import CmuxNextDaemon
public import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextRemote
public import CmuxNextUpdater
import Foundation

/// Update Everything's reads and steps over machines' daemons (cx-1mbnu), kept out of
/// CmuxNextApp: what each machine would update, each daemon's own `agent-update-*` for its agent
/// CLIs and threads (the logic lives in the daemon), the wait for a replaced daemon, and the
/// confirmation and result toast. The App only finds the services.
@MainActor
public enum UpdateEverythingDaemon {
    /// How long a machine may take to answer again after its update, or to reconnect at launch.
    public static let reconnectLimit: Duration = .seconds(180)

    /// One machine to read: its id, name, kind and daemon.
    public typealias Target = (String, String, UpdateEverythingMachine.Kind, DaemonService)

    /// The plan of `targets` (This Mac first), all asked at once: a remote machine whose daemon runs
    /// another build than the bundled cmux-tui gets a daemon update (a daemon that does not answer
    /// within 45 s shows only that), and This Mac the app's update when Sparkle has staged one (only
    /// then does Install relaunch at once, so the run's last step is the relaunch).
    public static func plan(_ targets: [Target], updater: UpdaterService) async -> UpdateEverythingPlan {
        var bundled: String?
        if let binary = try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment) {
            bundled = await BundledCmuxTUI.commit(binary: binary)
        }
        var plan = UpdateEverythingPlan(machines: await machines(targets, bundled: bundled))
        if !plan.machines.isEmpty, updater.installUnavailableReason == nil, case .ready(let version) = updater.flow.phase {
            let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ProcessInfo.processInfo.processName
            plan.machines[0].app = UpdateEverythingChange(name: name, from: updater.status.version, to: updater.stagedVersion ?? version)
        }
        return plan
    }

    private static func machines(_ targets: [Target], bundled: String?) async -> [UpdateEverythingMachine] {
        await withTaskGroup(of: (Int, UpdateEverythingMachine).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { (index, await machine(target, bundled: bundled)) }
            }
            var collected: [(Int, UpdateEverythingMachine)] = []
            for await machine in group { collected.append(machine) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func machine(_ target: Target, bundled: String?) async -> UpdateEverythingMachine {
        let (id, name, kind, daemon) = target
        var machine = UpdateEverythingMachine(id: id, name: name, kind: kind)
        let running = daemon.identity?.buildCommit.flatMap { $0.isEmpty ? nil : $0 }
        if let bundled, kind != .local, running.map({ !bundled.hasPrefix($0) && !$0.hasPrefix(bundled) }) ?? true {
            machine.daemon = UpdateEverythingChange(name: UpdateEverythingMachine.daemonName, from: running.map { String($0.prefix(7)) },
                                                    to: String(bundled.prefix(7)))
        }
        let agents = await agentPlan(daemon)
        machine.harnesses = agents.map(changes) ?? []
        machine.runningThreads = agents?.runningThreads ?? 0
        return machine
    }

    /// The daemon's outdated agent CLIs as it lists them now.
    public static func outdatedAgents(_ daemon: DaemonService?) async -> [UpdateEverythingChange] {
        guard let daemon else { return [] }
        return await agentPlan(daemon).map(changes) ?? []
    }

    private static func agentPlan(_ daemon: DaemonService) async -> AgentUpdatePlanRequest.Response? {
        guard daemon.supports(AgentUpdatePlanRequest.capability), let connection = daemon.connection else { return nil }
        return try? await connection.request(AgentUpdatePlanRequest(), timeout: .seconds(45))
    }

    private static func changes(_ plan: AgentUpdatePlanRequest.Response) -> [UpdateEverythingChange] {
        plan.harnesses.map { UpdateEverythingChange(id: $0.id, name: $0.name ?? $0.id, from: $0.version, to: $0.latest) }
    }

    /// The daemon's update of `machine`'s agent CLIs, then of its threads with `continueThreads`.
    /// - Returns: Why some threads still run the old agent (they could not restart), or nil.
    /// - Throws: The first agent CLI that failed to update.
    public static func updateAgents(_ daemon: DaemonService?, _ machine: UpdateEverythingMachine,
                                    continueThreads: Bool) async throws -> String? {
        guard let connection = daemon?.connection else { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
        let request = AgentUpdateApplyRequest(ids: machine.harnesses.compactMap(\.id), continueThreads: continueThreads)
        let answer = try await connection.request(request, timeout: AgentUpdateApplyRequest.timeout)
        if let failed = answer.results.first(where: { !$0.ok }) {
            throw ActionFailure(message: UpdateEverythingOutcome.failureLine(failed.id, failed.error ?? ""))
        }
        return answer.threadsError
    }

    /// Waits until a new daemon (not `pid`) answers; the old connection stays until its handshake.
    /// - Throws: When none answers within ``reconnectLimit``.
    public static func waitForNewDaemon(_ daemon: DaemonService, replacing pid: Int32?) async throws {
        let answered = await holds { daemon.connection != nil && daemon.identity.map { $0.pid != pid } ?? false }
        if !answered { throw ActionFailure(message: UpdateEverythingMachine.disconnected) }
    }

    /// Whether `condition` holds within ``reconnectLimit``: an observation, bounded by a one-shot deadline.
    public static func holds(until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if condition() { return true }
        // concurrency-allow: the observation task exits on cancellation; this bounds a machine's reconnect
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await observe(condition) }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine to answer after its update
                try? await Task.sleep(for: reconnectLimit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    private static func observe(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        for await ready in ObservationStream({ condition() }) where ready { return true }
        return false
    }

    /// The action's run, under the caller's ``UpdateEverythingRunner/claim()``: reads `plan`, asks
    /// once, updates the machines and the app last, and shows the result.
    public static func ask(plan: () async -> UpdateEverythingPlan, runner: UpdateEverythingRunner,
                           steps: any UpdateEverythingSteps, window: () -> NSWindow?) async {
        let plan = await plan()
        guard !plan.isUpToDate else { return toast(UpdateEverythingRunner.everythingUpToDate, in: window()) }
        guard let shown = window(), let continueThreads = await confirm(plan, in: shown) else { return }
        toast(UpdateEverythingRunner.updating, duration: .seconds(45 * 60), in: window())
        report(await runner.run(plan, continueThreads: continueThreads, steps: steps), in: window())
    }

    /// `<Application Support>/<bundle id>/update-everything.json`.
    public static func journalURL(bundleID: String?) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        return support.appending(path: bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next").appending(path: "update-everything.json")
    }

    /// Asks once in `window`: a line per machine, the threads that restart, and "Continue threads
    /// after restarts" (on).
    /// - Returns: The person's "Continue threads after restarts", or nil when they cancel.
    public static func confirm(_ plan: UpdateEverythingPlan, in window: NSWindow) async -> Bool? {
        let prompt = UpdateEverythingPrompt(plan)
        let continueID = "continue-threads", confirmID = "confirm"
        let spec = CmuxDialogSpec(title: prompt.title, lines: prompt.lines,
                                  fields: [.check(id: continueID, title: prompt.continueThreads, on: true)],
                                  buttons: [.cancel(), CmuxDialogButton(id: confirmID, title: prompt.button, role: .default)],
                                  identifier: "cmux.dialog.updateEverything")
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        guard answer.button == confirmID else { return nil }
        return answer.values[continueID]?.bool ?? true
    }

    /// The run's one toast in `window`.
    public static func toast(_ message: String, duration: Duration = .seconds(6), in window: NSWindow?) {
        guard let window else { return }
        CmuxToastCenter.shared.show(CmuxToast(id: "update-everything", message: message, duration: duration), in: window)
    }

    /// The run's result toast: every failure or thread left on the old agent by machine, or done.
    public static func report(_ outcomes: [UpdateEverythingOutcome], in window: NSWindow?) {
        let lines = UpdateEverythingOutcome.summary(outcomes)
        toast(lines ?? UpdateEverythingRunner.done, duration: .seconds(lines == nil ? 6 : 20), in: window)
    }
}
