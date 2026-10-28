@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextWakeups
import Foundation

extension TerminalThemeSetting {
    /// A setting on a scheduler with no display link (tests): its settings changes and deadlines run on
    /// main run loop turns, and it hears the day, time zone, clock and wake notices posted to `center`.
    /// `center` is the caller's to keep: the setting's AppEvents hold it weakly, so a released center
    /// leaves the setting deaf.
    @MainActor static func testing(backdropScope: ThemeScope, center: NotificationCenter) -> TerminalThemeSetting {
        TerminalThemeSetting(backdropScope: backdropScope, deadlines: MainDeadlineScheduler(work: linklessMainWork()),
                             appEvents: AppEvents(center: center), workspaceEvents: AppEvents(center: center))
    }
}
