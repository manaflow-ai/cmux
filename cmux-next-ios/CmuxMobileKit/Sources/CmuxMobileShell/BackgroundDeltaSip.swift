#if os(iOS)
import BackgroundTasks
import CmuxMobileLive
import Foundation
import OSLog
import UIKit

private let log = Logger(subsystem: "dev.cmux.mobile", category: "delta-sip")

/// Background delta sip. Leo, 2026-11-24: "the syncing can arguably happen in the background
/// too, so deltas can be sipped and maintained."
///
/// A `BGAppRefreshTask` wakes the app while it is closed. Each Mac then catches up: a Mac with a
/// link up gets one `catch-up` request, and a Mac that is asleep is read from the relay's sealed
/// delta log (`LiveCoordinator.sipDeltasInBackground`). The next open then has less to fetch, and
/// the phone stays inside the relay's delta log instead of falling back to a whole snapshot.
///
/// Off by default: a wake is asked for only while the Mac `catch-up` setting or the relay delta
/// catch-up setting is on (`LiveCoordinator.backgroundSipEnabled`). iOS decides when the wake
/// runs; `interval` is only the earliest time.
@MainActor
enum BackgroundDeltaSip {
    /// Listed in Info.plist `BGTaskSchedulerPermittedIdentifiers` (project.yml).
    static let taskIdentifier = "dev.cmux.mobile.delta-sip"
    /// The earliest next wake after a sip or after the app goes to the background.
    static let interval: TimeInterval = 15 * 60

    private static var backgroundObserver: NSObjectProtocol?

    /// Registers the wake handler (once, before launch ends) and asks for a wake each time the app
    /// goes to the background.
    static func register() {
        #if canImport(CmuxMobileLinkFFI)
        guard backgroundObserver == nil else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            MainActor.assumeIsolated { handle(task) }
        }
        guard registered else {
            log.error("delta sip: \(taskIdentifier, privacy: .public) is not permitted by Info.plist")
            return
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { schedule() }
        }
        #endif
    }

    #if canImport(CmuxMobileLinkFFI)
    /// Asks for the next wake, or cancels a pending one when both settings are off.
    static func schedule() {
        guard LiveCoordinator.backgroundSipEnabled() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.info("delta sip: no wake asked for: \(String(describing: error), privacy: .public)")
        }
    }

    private static func handle(_ task: BGTask) {
        schedule()
        let run = SipRun { task.setTaskCompleted(success: $0) }
        let work = Task { @MainActor in
            let ran = await PushReplies.shared.sipDeltasInBackground()
            run.finish(ran)
        }
        // iOS ends the app if the task outlives its time without being completed.
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in run.finish(false) }
        }
    }
    #endif
}

/// Completes a background task exactly once: the sip's end or the system's expiration, whichever
/// comes first.
@MainActor
final class SipRun {
    private var complete: ((Bool) -> Void)?

    init(complete: @escaping (Bool) -> Void) {
        self.complete = complete
    }

    func finish(_ success: Bool) {
        guard let complete else { return }
        self.complete = nil
        complete(success)
    }
}
#endif
