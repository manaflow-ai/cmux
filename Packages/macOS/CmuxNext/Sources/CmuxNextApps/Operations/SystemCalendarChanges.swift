import CmuxNextCompat
#if canImport(EventKit)
import EventKit
#endif
public import Foundation
import Observation

/// Counts the system calendar's changes (EventKit's `EKEventStoreChanged`: an event added, edited or
/// removed, in Calendar or by a sync, or access granted or taken away), so ``AppProviderChangeFeed/systemCalendar(_:)``
/// sends `system_calendar.changed` and a `cmux.watch("system_calendar.events")` reads again at once
/// instead of on a timer. EventKit posts the notice only while an `EKEventStore` lives, which
/// ``CalendarAppOps``' source keeps after its first read with access, the only time there is
/// anything to re-read. The composition root (AppsService) makes the one counter and hands it to the feed.
@MainActor
@Observable
public final class SystemCalendarChanges {
    /// Bumped once per change notice; only its changes matter.
    public private(set) var revision: UInt64 = 0
    @ObservationIgnored private var observation: MainActorObservation?

    /// Observes `EKEventStoreChanged` on `center` (tests pass their own center).
    /// - Parameter center: The notification center EventKit posts on.
    public init(center: NotificationCenter = .default) {
        #if canImport(EventKit)
        observation = MainActorObservation(.EKEventStoreChanged, center: center) { [weak self] in
            self?.revision &+= 1
        }
        #endif
    }
}

extension AppProviderChangeFeed {
    /// `system_calendar.changed` whenever EventKit says the calendars changed, so calendar widgets
    /// redraw from the event and the daemon drops its cached reads (`system_calendar.rs`).
    @MainActor public static func systemCalendar(_ changes: SystemCalendarChanges) -> AppProviderChangeFeed {
        AppProviderChangeFeed(family: "system_calendar") { changes.revision }
    }
}
