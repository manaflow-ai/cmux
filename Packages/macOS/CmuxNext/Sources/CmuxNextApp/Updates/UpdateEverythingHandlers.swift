import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextUpdateEverything
import Foundation

/// Update Everything (cx-1mbnu): the palette and app menu action reads what every machine would
/// update, asks once (a line per machine, the threads that restart, "Continue threads after
/// restarts" on), then updates the machines and the app last. A run the app relaunched in the
/// middle of finishes at the next launch, once the machines reconnect.
@MainActor
enum UpdateEverythingHandlers {
    static let actionID: ActionID = "updates.updateEverything"
    private static let continueID = "continue-threads"

    static func bind(into registry: ActionRegistry, services: AppServices) {
        let steps = UpdateEverythingAppSteps(services: services)
        let runner = UpdateEverythingRunner(journal: UpdateEverythingJournal(url: journalURL(services)))
        registry.bind(actionID, run: { _ in
            guard runner.claim() else { throw ActionFailure(message: UpdateEverythingStrings.alreadyRunning) }
            // task-owner: one confirmation and its run; ends with the run's result toast
            Task { @MainActor in
                defer { runner.release() }
                await ask(services, steps: steps, runner: runner)
            }
        })
        // task-owner: the launch's one check for a run the app relaunched in; ends with that run
        Task { @MainActor in
            guard let outcomes = await runner.finishAfterRelaunch(plan: { await steps.plan(waitingFor: $0) }, steps: steps) else { return }
            report(outcomes, services)
        }
    }

    private static func ask(_ services: AppServices, steps: UpdateEverythingAppSteps, runner: UpdateEverythingRunner) async {
        let plan = await steps.plan()
        guard !plan.isUpToDate else { return toast(services, UpdateEverythingStrings.everythingUpToDate) }
        guard let window = services.windows.active?.window ?? NSApp.mainWindow else { return }
        let prompt = UpdateEverythingPrompt(plan)
        let spec = CmuxDialogSpec(title: prompt.title, lines: prompt.lines,
                                  fields: [.check(id: continueID, title: prompt.continueThreads, on: true)],
                                  buttons: [.cancel(ConfirmationStrings.cancel),
                                            CmuxDialogButton(id: DestructiveConfirmation.confirmID, title: prompt.button, role: .default)],
                                  identifier: "cmux.dialog.updateEverything")
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        guard answer.button == DestructiveConfirmation.confirmID else { return }
        toast(services, UpdateEverythingStrings.updating, duration: .seconds(45 * 60))
        let outcomes = await runner.run(plan, continueThreads: answer.values[continueID]?.bool ?? true, steps: steps)
        report(outcomes, services)
    }

    /// One toast: every failure by machine, or done.
    private static func report(_ outcomes: [UpdateEverythingOutcome], _ services: AppServices) {
        let failures = outcomes.compactMap { outcome in outcome.failure.map { UpdateEverythingStrings.failed(outcome.name, $0) } }
        toast(services, failures.isEmpty ? UpdateEverythingStrings.done : failures.joined(separator: "\n"),
              duration: .seconds(failures.isEmpty ? 6 : 20))
    }

    private static func toast(_ services: AppServices, _ message: String, duration: Duration = .seconds(6)) {
        guard let window = services.windows.active?.window ?? NSApp.mainWindow else { return }
        CmuxToastCenter.shared.show(CmuxToast(id: "update-everything", message: message, duration: duration), in: window)
    }

    /// `<Application Support>/<bundle id>/update-everything.json`.
    private static func journalURL(_ services: AppServices) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = services.environment.launch.bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return support.appending(path: bundle).appending(path: "update-everything.json")
    }
}
