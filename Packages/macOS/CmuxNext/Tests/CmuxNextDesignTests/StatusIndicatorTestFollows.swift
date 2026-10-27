import AppKit
@testable import CmuxNextDesign
import CmuxNextWakeups

/// A test's stand-in for the composition root's follows of a ``StatusIndicatorAppearance``: its own app and
/// workspace centers, one ``AppEvents`` per center and a main-work scheduler whose link never fires. Keep it for
/// the whole test: an ``AppEvents`` holds its center weakly.
@MainActor final class StatusIndicatorTestFollows {
    let app: NotificationCenter
    let workspace: NotificationCenter
    let appEvents: AppEvents
    let workspaceEvents: AppEvents
    let work: MainWorkScheduler

    init(app: NotificationCenter = NotificationCenter(), workspace: NotificationCenter = NotificationCenter()) {
        self.app = app
        self.workspace = workspace
        appEvents = AppEvents(center: app)
        workspaceEvents = AppEvents(center: workspace)
        work = MainWorkScheduler.testing { _ in StatusIndicatorStillLink() }
    }

    /// Starts `appearance`'s config and resync follows on these centers, as `AppDelegate` does before the first window.
    func start(_ appearance: StatusIndicatorAppearance) {
        appearance.observe(on: work, appEvents: appEvents, workspaceEvents: workspaceEvents)
    }
}

/// A display link that never fires: the follows' first read is synchronous, and no test here steps frames.
@MainActor final class StatusIndicatorStillLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
