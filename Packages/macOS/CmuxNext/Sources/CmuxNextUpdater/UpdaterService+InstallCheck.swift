import Foundation

/// An install that left the old build running says why (``UpdateInstallCheck``).
extension UpdaterService {
    /// Sparkle is about to relaunch into the build it installs: the next launch judges whether it did.
    func recordInstallCheck() {
        let record = installingBuild.map { UpdateInstallCheck(fromBuild: identity.build, targetBuild: $0, recordedAt: now()) }
        UpdateInstallCheck.write(record, defaults: defaults)
    }

    /// The install ended with this app still running: no relaunch judges it, so its record goes
    /// (a later launch of this build must not read as a failed install), and the windows come back.
    func abandonInstall() {
        UpdateInstallCheck.write(nil, defaults: defaults)
        installAbandoned?()
    }

    /// At launch: the install the last relaunch was for, read once. Still on the build it was meant
    /// to replace, the install failed; the log and the staged update card say why.
    func checkLastInstall() {
        guard let last = UpdateInstallCheck.consume(defaults: defaults, build: identity.build, now: now()) else { return }
        switch last.outcome {
        case .installed:
            log.append("installed \(last.record.targetBuild) over \(last.record.fromBuild)")
        case .failed:
            // concurrency-allow: once per launch after a failed install: a path test, two access checks and one volume read.
            let failure = UpdateInstallFailure.diagnose(bundle: Bundle.main.bundleURL)
            failedInstall = (last.record.targetBuild, failure)
            log.append("install of \(last.record.targetBuild) did not replace \(last.record.fromBuild): \(failure)")
        }
    }
}
