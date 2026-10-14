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
    /// A run is going; a second request while one runs is refused.
    public private(set) var isRunning = false
    @ObservationIgnored private let journal: UpdateEverythingJournal

    /// - Parameter journal: Where the run notes what the relaunched app must finish.
    public init(journal: UpdateEverythingJournal) {
        self.journal = journal
    }

    /// Updates every machine of `plan`, then the app.
    /// - Parameters:
    ///   - plan: What the person confirmed.
    ///   - continueThreads: The person's "Continue threads after restarts".
    ///   - steps: The App's update paths.
    /// - Returns: One outcome per machine that had work, in plan order; empty when a run was going.
    ///   An app update that starts relaunches the app, so its outcome is never read.
    public func run(_ plan: UpdateEverythingPlan, continueThreads: Bool, steps: any UpdateEverythingSteps) async -> [UpdateEverythingOutcome] {
        guard !isRunning else { return [] }
        isRunning = true
        defer { isRunning = false }
        let machines = plan.machines.filter { $0.daemon != nil || !$0.harnesses.isEmpty || $0.app != nil }
        var outcomes = await withTaskGroup(of: (Int, UpdateEverythingOutcome).self) { group in
            for (index, machine) in machines.enumerated() {
                group.addTask { @MainActor in (index, await Self.update(machine, continueThreads: continueThreads, steps: steps)) }
            }
            var collected: [(Int, UpdateEverythingOutcome)] = []
            for await outcome in group { collected.append(outcome) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if let local = machines.first(where: { $0.app != nil }),
           let index = outcomes.firstIndex(where: { $0.machineID == local.id }), outcomes[index].failure == nil {
            do {
                try await journal.save(continueThreads: continueThreads)
                try steps.installApp()
            } catch {
                await journal.clear()
                outcomes[index].failure = Self.text(error)
            }
        }
        return outcomes
    }

    /// Finishes a run the app relaunched in the middle of: nil when no fresh note says one was
    /// going. The note is removed first, so a crash here never repeats the run.
    /// - Parameters:
    ///   - plan: Reads the plan now (the relaunched app's daemon build against each machine).
    ///   - steps: The App's update paths.
    /// - Returns: The outcomes of the finished run, or nil.
    public func finishAfterRelaunch(plan: () async -> UpdateEverythingPlan, steps: any UpdateEverythingSteps) async -> [UpdateEverythingOutcome]? {
        guard let entry = await journal.take() else { return nil }
        var fresh = await plan()
        // The app just updated: a second Sparkle update found meanwhile waits for the next run.
        for index in fresh.machines.indices { fresh.machines[index].app = nil }
        return await run(fresh, continueThreads: entry.continueThreads, steps: steps)
    }

    /// One machine's daemon, agent CLIs and threads, stopping at its first failure.
    private static func update(_ machine: UpdateEverythingMachine, continueThreads: Bool,
                               steps: any UpdateEverythingSteps) async -> UpdateEverythingOutcome {
        var outcome = UpdateEverythingOutcome(machineID: machine.id, name: machine.name)
        do {
            if machine.daemon != nil { try await steps.updateDaemon(on: machine) }
            if !machine.harnesses.isEmpty { try await steps.updateAgents(on: machine, continueThreads: continueThreads) }
        } catch {
            outcome.failure = text(error)
        }
        return outcome
    }

    private static func text(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
