import CmuxConnectivityTelemetry
import CmuxNextCompat
import CmuxNextCrashReporting
import Foundation

/// Where the Mac's connectivity telemetry (``ConnectivityTelemetry``: the Cloud link, the phone
/// host, pairing) goes: a journal per build
/// (`~/Library/Application Support/cmux-next/<bundle id>/connectivity.jsonl`, 2 x 1 MB), the
/// unified log (`com.cmuxterm.app.next`, category `connectivity`), and Sentry while the person's
/// anonymous telemetry is on (``CrashReporter/connectivitySink()``). The audience follows the
/// signed-in account: a `@manaflow.ai` or `@cmux.com` account records verbosely.
@MainActor
enum ConnectivityReporting {
    static func install(services: AppServices) {
        let telemetry = ConnectivityTelemetry.shared
        telemetry.setJournal(ConnectivityJournal(directory: journalDirectory(bundleID: services.environment.launch.bundleID)))
        telemetry.addSink(ConnectivityTelemetry.unifiedLogSink(subsystem: "com.cmuxterm.app.next"))
        telemetry.addSink(services.crashReporting.reporter.connectivitySink())
        follow(ObservationStream { [weak auth = services.cloud.auth] in
            auth.flatMap { auth in auth.isSignedIn ? auth.user?.primaryEmail : nil }
        }, telemetry: telemetry)
    }

    /// The build's own directory, beside its run marker (a tagged DEV build never shares one).
    static func journalDirectory(bundleID: String?) -> URL {
        AppRunMarker.standardDirectory(bundleID: bundleID)
    }

    /// Sets the audience from each signed-in email for the app's lifetime.
    static func follow(_ emails: ObservationStream<String?>, telemetry: ConnectivityTelemetry) {
        // task-owner: lives for the app; ends when `emails` ends.
        Task {
            for await email in emails { telemetry.setAccount(email: email) }
        }
    }
}
