import Foundation

extension UpdaterService {
    /// How long `cmux app relaunch` waits after its answer before it quits, so the reply reaches
    /// the caller before the control socket closes.
    static let relaunchAnswerLead: Duration = .milliseconds(300)

    /// `cmux app relaunch` (Leo, 2026-11-22: "approved ways to simply do the update and restart
    /// button's flow should be available"): quits with Keep Sessions and opens the bundle
    /// installed now, the path Restart to Update takes for a build already on disk
    /// (``relaunchIntoInstalledBuild()``). A nightly replaced under a running app included. With
    /// `ifNewer`, it refuses unless the installed build is newer than the running one. Never a kill:
    /// the helper waits for this process to quit, then opens the bundle.
    public func relaunchAnswer(ifNewer: Bool) -> Task<UpdateCommandAnswer, Never> {
        let running = identity.build
        guard relaunchInstalledBuild != nil else { return Task { .refused("this build cannot relaunch itself") } }
        guard let installed = readInstalledBuild() else { return Task { .refused("the app bundle on disk could not be read") } }
        let newer = InstalledBuildWatch.isNewer(installed.build, than: running)
        if ifNewer, !newer {
            return Task { .refused("the installed build \(installed.build) is not newer than the running build \(running)") }
        }
        log.append("relaunch: running \(running), installed \(installed.build); quitting with Keep Sessions")
        relaunchTimer.schedule(after: Self.relaunchAnswerLead) { @MainActor [weak self] in
            guard let self, let relaunch = self.relaunchInstalledBuild else { return }
            self.updaterWillRelaunchApplication()
            relaunch()
        }
        let fields: [String: UpdateAnswerField] = [
            "relaunching": .bool(true), "running_build": .string(running),
            "installed_build": .string(installed.build), "newer": .bool(newer),
        ]
        return Task { .answered(fields) }
    }
}
