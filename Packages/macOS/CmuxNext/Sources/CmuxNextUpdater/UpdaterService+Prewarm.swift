import CmuxNextWakeups
import Foundation

extension UpdaterService {
    /// Pre-warms the staged build's first launch once per build (``StagedUpdatePrewarm``), while
    /// the update waits for Restart to Update or an idle install. Only a build newer than the
    /// running one: it knows ``StagedUpdatePrewarm/argument`` because the running build does, so
    /// an older staged build (a switch back) never gets an argument it would not stop on.
    ///
    /// Every outcome goes to the update log at once: `launch pre-warm of <build>: started`, then a
    /// line after the scan and after each run, or `launch pre-warm: skipped (<why>)` once per build
    /// and reason. A pre-warm that never ran can no longer be silent (Leo's NIGHTLY had no line at all).
    func prewarmStagedUpdate() {
        guard let build = stagedBuild(), !build.isEmpty else { return skipPrewarm(of: nil, "no staged build") }
        guard prewarmedBuild != build else { return }
        guard let bundleIdentifier = identity.bundleIdentifier else { return skipPrewarm(of: build, "no bundle id") }
        guard AppcastSelector.isOlder(identity.build, than: build) else {
            return skipPrewarm(of: build, "staged build \(build) is not newer than running build \(identity.build)")
        }
        prewarmedBuild = build
        log.append("launch pre-warm of \(build): started")
        let prewarm = StagedUpdatePrewarm(installation: UpdateInstallPreflight.stagedInstallation(bundleIdentifier: bundleIdentifier),
                                          bundleIdentifier: bundleIdentifier, build: build)
        let runner = prewarmRunner, log = log, work = work
        // The build's first launch records itself as pre-warmed (`cmux app launch-times`); no test writes the person's marker.
        let process = ProcessInfo.processInfo
        let marker = UpdateLogFile.isTestProcess(name: process.processName, environment: process.environment)
            ? nil : StagedUpdatePrewarm.launchMarkerURL(bundleIdentifier: bundleIdentifier)
        // task-owner: one pre-warm per staged build; ends after its last process (each stopped at its timeout).
        // Best effort: nobody waits for it; its folder scan runs on a files lane slot of its own
        // (``StagedUpdatePrewarm/perform(work:processes:timeout:marker:progress:)``), its processes through AsyncProcess.
        Task.detached(priority: WorkPriority.bestEffort.taskPriority) {
            if let runner {
                log.append(await runner(prewarm))
            } else {
                log.append(await prewarm.perform(work: work, marker: marker, progress: { log.append($0) }))
            }
        }
    }

    /// Logs why the staged build's pre-warm did not start, once per build and reason.
    private func skipPrewarm(of build: String?, _ reason: String) {
        let key = "\(build ?? "")|\(reason)"
        guard prewarmSkipLogged != key else { return }
        prewarmSkipLogged = key
        log.append("launch pre-warm: skipped (\(reason))")
    }
}
