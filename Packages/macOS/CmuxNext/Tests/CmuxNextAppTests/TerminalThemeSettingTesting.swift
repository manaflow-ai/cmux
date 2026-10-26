@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextWakeups
import Foundation

extension TerminalThemeSetting {
    /// A setting on a scheduler with no display link (tests): its settings changes and deadlines run on
    /// main run loop turns, and it hears the day, time zone and clock changes posted to `center`.
    @MainActor static func testing(backdropScope: ThemeScope, center: NotificationCenter = NotificationCenter()) -> TerminalThemeSetting {
        TerminalThemeSetting(backdropScope: backdropScope, deadlines: MainDeadlineScheduler(work: linklessMainWork()),
                             appEvents: AppEvents(center: center))
    }
}
