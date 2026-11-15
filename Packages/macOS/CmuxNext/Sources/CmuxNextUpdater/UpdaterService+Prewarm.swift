import CmuxNextWakeups
import Foundation

extension UpdaterService {
    /// Pre-warms the staged build's first launch once per build (``StagedUpdatePrewarm``), while
    /// the update waits for Restart to Update or an idle install. Only a build newer than the
    /// running one: it knows ``StagedUpdatePrewarm/argument`` because the running build does, so
    /// an older staged build (a switch back) never gets an argument it would not stop on.
    func prewarmStagedUpdate() {
        guard let build = stagedBuild(), !build.isEmpty, prewarmedBuild != build,
              let bundleIdentifier = identity.bundleIdentifier,
              AppcastSelector.isOlder(identity.build, than: build) else { return }
        prewarmedBuild = build
        let prewarm = StagedUpdatePrewarm(installation: UpdateInstallPreflight.stagedInstallation(bundleIdentifier: bundleIdentifier),
                                          bundleIdentifier: bundleIdentifier, build: build)
        let runner = prewarmRunner, log = log, work = work
        // task-owner: one pre-warm per staged build; ends after its last process (each stopped at its timeout).
        // Best effort: nobody waits for it; its folder scan runs on a files lane, its processes through AsyncProcess.
        Task.detached(priority: WorkPriority.bestEffort.taskPriority) {
            if let runner { log.append(await runner(prewarm)) } else { log.append(await prewarm.perform(work: work)) }
        }
    }
}
