public import CmuxNextCompat
public import Foundation
import os

extension DaemonLauncher {
    private static let buildLogger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")

    /// The app daemon's session and state directory of `build` (per-build
    /// isolation S3, cx-is1kf.4): ``BuildIdentity/appSession`` and
    /// ``BuildIdentity/daemonStateDirectory(appSupport:)`` under
    /// `<applicationSupport>/cmux`. With `log` (the app launcher), a build
    /// whose names are of its key (the untagged DEV build among them) logs
    /// them, so a developer can find its session.
    public static func appNames(build: BuildIdentity, applicationSupport: URL = applicationSupportDirectory(),
                                log: Bool = false) -> (session: String, stateDirectory: URL?) {
        let session = build.appSession ?? "cmux-app"
        let stateDirectory = build.daemonStateDirectory(
            appSupport: applicationSupport.appendingPathComponent("cmux", isDirectory: true))
        if log, !build.keepsAppNames {
            buildLogger.notice(
                "build \(build.key, privacy: .public) has per-build daemon session \(session, privacy: .public), state \(stateDirectory?.path ?? "default", privacy: .public)")
        }
        return (session, stateDirectory)
    }
}
