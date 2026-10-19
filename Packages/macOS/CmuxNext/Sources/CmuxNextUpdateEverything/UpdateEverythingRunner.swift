public import Foundation
public import Observation

/// Runs an Update Everything plan: every machine at once (its daemon, then its agent CLIs, then
/// its threads), and the app's own update last, after a ``UpdateEverythingJournal`` note, because
/// it relaunches. The relaunched app calls ``finishAfterRelaunch(plan:steps:)``: its bundled
/// daemon build is newer, so the machines updated before the relaunch are updated once more to it.
///
/// ```swift
/// let runner = UpdateEverythingRunner(journal: UpdateEverythingJournal(url: noteURL))
/// let outcomes = await runner.run(plan, continueThreads: true, steps: appSteps)
/// ```
@MainActor
@Observable
public final class UpdateEverythingRunner {
    /// A run is being asked about or goes; a second request meanwhile is refused.
    public private(set) var isBusy = false
    @ObservationIgnored private let journal: UpdateEverythingJournal

    /// - Parameter journal: Where the run notes what the relaunched app must finish.
    public init(journal: UpdateEverythingJournal) {
        self.journal = journal
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
        let machines = plan.machines.filter { !$0.isUpToDate }
        var outcomes = await withTaskGroup(of: (Int, UpdateEverythingOutcome).self) { group in
            for (index, machine) in machines.enumerated() {
                // No `@MainActor in`: the 6.3 region checker rejects that closure here; update is main-actor anyway.
                group.addTask { (index, await Self.update(machine, continueThreads: continueThreads, steps: steps)) }
            }
            var collected: [(Int, UpdateEverythingOutcome)] = []
            for await outcome in group { collected.append(outcome) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if let local = machines.first(where: { $0.app != nil }),
           let index = outcomes.firstIndex(where: { $0.machineID == local.id }), outcomes[index].failure == nil {
            do {
                let remotes = plan.machines.filter { $0.kind != .local }.map(\.id)
                try await journal.save(continueThreads: continueThreads, machineIDs: remotes)
                try steps.installApp()
            } catch {
                await journal.clear()
                outcomes[index].failure = Self.text(error)
            }
        }
        return outcomes
    }

    /// Finishes a run the app relaunched in the middle of: nil when no fresh note says one was
    /// going, or a run is reserved. The note is removed first, so a crash here never repeats the run.
    /// - Parameters:
    ///   - plan: Reads the plan once the machines the run named are back (it waits, bounded).
    ///   - steps: The App's update paths.
    /// - Returns: The outcomes of the finished run, or nil.
    public func finishAfterRelaunch(plan: ([String]) async -> UpdateEverythingPlan,
                                    steps: any UpdateEverythingSteps) async -> [UpdateEverythingOutcome]? {
        guard let entry = await journal.take(), claim() else { return nil }
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
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
