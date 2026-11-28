import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

/// OSC 7501 notifications (cx-kxa2): the daemon posts them; here the app
/// finds the record behind one, drops a `done` the user can already see, and
/// gives the banner a status badge image.
extension NotificationCenterService {
    /// The OSC 7501 record a `terminal` notification was posted for.
    func programStatus(of notification: DaemonNotification, source: NotificationSource,
                       located: LocatedTab) -> ProgramStatusNotification? {
        guard source == .terminal else { return nil }
        return ProgramStatusNotification.match(title: notification.title, body: notification.body,
                                               level: notification.level, records: located.tab.programStatus)
    }

    /// How long an alert waits for its record before it shows without one.
    static let programAlertWait: Duration = .milliseconds(1500)

    /// Holds an alert-shaped `terminal` notification until the tab's OSC 7501
    /// records contain its record (observed, no poll), then calls `deliver`
    /// once with the match; after `programAlertWait` it delivers without one.
    func holdUntilRecord(_ notification: DaemonNotification, located: LocatedTab,
                         deliver: @escaping @MainActor @Sendable (ProgramStatusNotification?) -> Void) {
        let id = notification.notification.rawValue
        let tab = located.tab
        let hold = HeldProgramAlert(timer: DemandTimer(owner: "notifications.programAlert", clock: clock))
        let finish: @MainActor @Sendable (ProgramStatusNotification?) -> Void = { [weak self] found in
            guard !hold.delivered else { return }
            hold.delivered = true
            hold.timer.cancel()
            self?.heldProgramAlerts.removeValue(forKey: id)?.cancel()
            deliver(found)
        }
        hold.timer.schedule(after: Self.programAlertWait) { @MainActor in finish(nil) }
        heldProgramAlerts[id] = Task { @MainActor in // task-owner: heldProgramAlerts, cancelled by finish
            for await records in ObservationStream({ tab.programStatus }) {
                if let found = ProgramStatusNotification.match(title: notification.title, body: notification.body,
                                                                level: notification.level, records: records) {
                    finish(found)
                    return
                }
            }
        }
    }

    /// Where the tab is for the user now (status-indicators.md visibility
    /// rule): drawn by a visible window, while cmux is active. A tab on an
    /// inactive screen, under a top page or scrolled out of view is not.
    func visibility(of located: LocatedTab) -> TerminalVisibility {
        guard let services else { return .hidden }
        // One window must both draw the tab (``WindowController/showsOnScreen(_:in:)``) and be visible; flags
        // from different windows never combine.
        let shown = services.windows.controllers.contains { controller in
            controller.showsOnScreen(located.tab.id, in: located.pane) && (controller.window?.occlusionState.contains(.visible) ?? false)
        }
        var visibility = TerminalVisibility.hidden
        visibility.appActive = services.appActiveSource()
        if shown {
            visibility.tabSelected = true
            visibility.paneOnScreen = true
            visibility.windowShown = true
        }
        return visibility
    }
}

/// One held OSC 7501 alert: delivered once, by its record or its deadline.
@MainActor
final class HeldProgramAlert {
    let timer: DemandTimer
    var delivered = false
    init(timer: DemandTimer) { self.timer = timer }
}
