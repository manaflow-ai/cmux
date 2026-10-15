import AppKit
import CmuxNextActions
import CmuxNextUpdateEverything

/// Update Everything (cx-1mbnu): the palette and app menu action reads what every machine would
/// update, asks once, then updates the machines and the app last (``UpdateEverythingDaemon``). A
/// run the app relaunched in the middle of finishes at the next launch, once the machines reconnect.
@MainActor
enum UpdateEverythingHandlers {
    static let actionID: ActionID = "updates.updateEverything"

    static func bind(into registry: ActionRegistry, services: AppServices) {
        let steps = UpdateEverythingAppSteps(services: services)
        let runner = UpdateEverythingRunner(journal: UpdateEverythingJournal(url: UpdateEverythingDaemon.journalURL(bundleID: services.environment.launch.bundleID)))
        let window = { services.windows.active?.window ?? NSApp.mainWindow }
        registry.bind(actionID, run: { _ in
            guard runner.claim() else { throw ActionFailure(message: UpdateEverythingRunner.alreadyRunning) }
            // task-owner: one confirmation and its run; ends with the run's result toast
            Task { @MainActor in
                defer { runner.release() }
                await UpdateEverythingDaemon.ask(plan: { await steps.plan() }, runner: runner, steps: steps, window: window)
            }
        })
        // task-owner: the launch's one check for a run the app relaunched in; ends with that run
        Task { @MainActor in
            guard let outcomes = await runner.finishAfterRelaunch(plan: { await steps.plan(waitingFor: $0) }, steps: steps) else { return }
            UpdateEverythingDaemon.report(outcomes, in: window())
        }
    }
}
