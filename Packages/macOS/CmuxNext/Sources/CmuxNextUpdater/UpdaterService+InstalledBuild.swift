import Foundation

extension UpdaterService {
    /// The newer build installed in this app's bundle on disk while this process still runs the
    /// build it launched with, or nil (``InstalledBuildWatch``). It offers the same Restart to Update
    /// as a staged update (``restartableUpdate``, ``readyCard``), and never relaunches by itself.
    public var installedBuild: InstalledBuild? { installedNewerBuild }

    /// Reads the bundle on disk now. Called at launch, when the app becomes active, and after every
    /// update cycle (Sparkle's scheduled, launch, wake or asked check); nothing polls.
    public func checkInstalledBuild() {
        // A local development build is rebuilt under itself all day: it never nags.
        guard identity.track != .development else { return }
        let found = InstalledBuildWatch.newerInstalledBuild(running: identity.build, installed: readInstalledBuild())
        guard found != installedNewerBuild else { return }
        installedNewerBuild = found
        log.append(found.map { "the installed build \($0.build) is newer than the running build \(identity.build)" }
            ?? "the installed build is the running build again")
    }

    /// Restart to Update with no staged update: the installed build is already on disk, so the app
    /// only has to quit and open again. Returns whether it took the click.
    func relaunchIntoInstalledBuild() -> Bool {
        guard installedNewerBuild != nil, !hasStagedSparkleUpdate, let relaunchInstalledBuild else { return false }
        log.append("restart to update: relaunching into the installed build")
        updaterWillRelaunchApplication()
        relaunchInstalledBuild()
        return true
    }

    /// Whether Sparkle itself holds a downloaded update (its install, not a relaunch, is the click).
    var hasStagedSparkleUpdate: Bool {
        if case .ready = sourcePhase { return true }
        return false
    }
}
