public import Foundation
public import Observation

/// Runs an Update Everything plan: every machine at once (its daemon, then its agent CLIs, then
/// its threads), and the app's own update last, after a ``UpdateEverythingJournal`` note, because
/// it relaunches. A run that relaunches leaves the machines' daemons (and the agent CLIs behind
/// them) to the relaunched app's ``finishAfterRelaunch(plan:steps:)``: its bundled daemon build is
/// newer, so each daemon is replaced once, with that build.
///
/// ```swift
/// let runner = UpdateEverythingRunner(journal: UpdateEverythingJournal(url: noteURL), appVersion: "1234")
/// let outcomes = await runner.run(plan, continueThreads: true, steps: appSteps)
/// ```
@MainActor
@Observable
public final class UpdateEverythingRunner {
    /// A run is being asked about or goes; a second request meanwhile is refused.
    public private(set) var isBusy = false
    @ObservationIgnored private let journal: UpdateEverythingJournal
    @ObservationIgnored private let appVersion: String?

    /// - Parameters:
    ///   - journal: Where the run notes what the relaunched app must finish.
    ///   - appVersion: This app's build (`CFBundleVersion`): a note is finished only by a launch of
    ///     another build, so an app update that failed or was postponed after it started never
    ///     finishes a run unasked. Nil finishes nothing.
    public init(journal: UpdateEverythingJournal, appVersion: String?) {
        self.journal = journal
        self.appVersion = appVersion
    }

    /// Reserves the runner from the moment the person asks (before the plan and the
    /// confirmation), so two requests never both run.
    /// - Returns: False when a run is already reserved.
    public func claim() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    /// Ends the reservation ``claim()`` made.
    public func release() {
        isBusy = false
    }

    /// Updates every machine of `plan`, then the app. The caller holds ``claim()``.
    /// - Parameters:
    ///   - plan: What the person confirmed.
    ///   - continueThreads: The person's "Continue threads after restarts".
    ///   - steps: The App's update paths.
    /// - Returns: One outcome per machine that had work, in plan order. An app update that starts
    ///   relaunches the app, so its outcome is never read.
    public func run(_ plan: UpdateEverythingPlan, continueThreads: Bool, steps: any UpdateEverythingSteps) async -> [UpdateEverythingOutcome] {
        let machines = Array(plan.machines.filter { !$0.isUpToDate }.enumerated())
        // A relaunch brings a newer daemon build: a remote daemon updated now would be replaced
        // again after it, so it (and the agent CLIs it lists) waits for the relaunched app.
        let waits = { (machine: UpdateEverythingMachine) in plan.relaunches && machine.kind != .local && machine.daemon != nil }
        var outcomes = await Self.update(machines.filter { !waits($0.element) }, continueThreads: continueThreads, steps: steps)
        var relaunching = false
        if let local = machines.first(where: { $0.element.app != nil }),
           let index = outcomes.firstIndex(where: { $0.0 == local.offset }), outcomes[index].1.failure == nil {
            do {
                let remotes = plan.machines.filter { $0.kind != .local }.map(\.id)
                try await journal.save(continueThreads: continueThreads, machineIDs: remotes, appVersion: appVersion)
                try steps.installApp()
                relaunching = true
            } catch {
                await journal.clear()
                outcomes[index].1.failure = Self.text(error)
            }
        }
        // No relaunch comes: the waiting daemons update to this app's build now.
        if !relaunching {
            outcomes += await Self.update(machines.filter { waits($0.element) }, continueThreads: continueThreads, steps: steps)
        }
        return outcomes.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Every one of `machines` at once, each with its index in the run.
    private static func update(_ machines: [(offset: Int, element: UpdateEverythingMachine)], continueThreads: Bool,
                               steps: any UpdateEverythingSteps) async -> [(Int, UpdateEverythingOutcome)] {
        await withTaskGroup(of: (Int, UpdateEverythingOutcome).self) { group in
            for (index, machine) in machines {
                // No `@MainActor in`: the 6.3 region checker rejects that closure here; update is main-actor anyway.
                group.addTask { (index, await Self.update(machine, continueThreads: continueThreads, steps: steps)) }
            }
            var collected: [(Int, UpdateEverythingOutcome)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
    }

    /// Finishes a run the app relaunched in the middle of: nil when no fresh note says one was
    /// going, this launch runs the build the run started from (the app update did not happen), or
    /// a run is reserved. The note is removed first, so a crash here never repeats the run.
    /// - Parameters:
    ///   - plan: Reads the plan once the machines the run named are back (it waits, bounded).
    ///   - steps: The App's update paths.
    /// - Returns: The outcomes of the finished run, or nil.
    public func finishAfterRelaunch(plan: ([String]) async -> UpdateEverythingPlan,
                                    steps: any UpdateEverythingSteps) async -> [UpdateEverythingOutcome]? {
        guard let entry = await journal.take(runningVersion: appVersion), claim() else { return nil }
        defer { release() }
        var fresh = await plan(entry.machineIDs)
        // The app just updated: a second Sparkle update found meanwhile waits for the next run.
        for index in fresh.machines.indices { fresh.machines[index].app = nil }
        return await run(fresh, continueThreads: entry.continueThreads, steps: steps)
    }

    /// One machine's daemon, agent CLIs and threads, stopping at its first failure.
    private static func update(_ machine: UpdateEverythingMachine, continueThreads: Bool,
                               steps: any UpdateEverythingSteps) async -> UpdateEverythingOutcome {
        var outcome = UpdateEverythingOutcome(machineID: machine.id, name: machine.name)
        do {
            var machine = machine
            if machine.daemon != nil {
                try await steps.updateDaemon(on: machine)
                // A daemon too old to list agent CLIs lists them once it runs the new build.
                machine.harnesses = await steps.outdatedAgents(on: machine)
            }
            if !machine.harnesses.isEmpty { outcome.threadsLeft = try await steps.updateAgents(on: machine, continueThreads: continueThreads) }
        } catch {
            outcome.failure = text(error)
        }
        return outcome
    }

    private static func text(_ error: any Error) -> String {
        UpdateEverythingMachine.failureText((error as? any LocalizedError)?.errorDescription ?? String(describing: error))
    }
}
