import AppKit
#if canImport(EventKit)
import EventKit
#endif
import Foundation

/// The Mac's calendars through EventKit, for `SystemCalendarAppOps`.
///
/// An actor: EventKit's predicate reads are synchronous and can take a while
/// on a large calendar database, so they run on this actor's executor, never
/// on the main thread. The store is created on first use, so a person who
/// never adds a calendar widget never loads EventKit. The usage strings are
/// `NSCalendarsFullAccessUsageDescription` and `NSCalendarsUsageDescription`
/// in `Resources/Info.plist`; the signed app carries
/// `com.apple.security.personal-information.calendars`.
public actor EventKitCalendarStore: SystemCalendarStore {
    #if canImport(EventKit)
    private var store: EKEventStore?

    private func eventStore() -> EKEventStore {
        if let store { return store }
        let made = EKEventStore()
        store = made
        return made
    }
    #endif

    /// Creates the store; EventKit itself loads on the first read.
    public init() {}

    /// The access macOS reports now (macOS 14's full access counts as granted; write-only does not).
    public func access() async -> SystemCalendarAccess {
        #if canImport(EventKit)
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied, .writeOnly: return .denied
        @unknown default: return .denied
        }
        #else
        return .restricted
        #endif
    }

    /// Shows macOS's Calendars question (full access: the widget reads events).
    public func requestAccess() async -> SystemCalendarAccess {
        #if canImport(EventKit)
        // The completion form: the store stays on this actor while macOS asks.
        // A refused or failed request reads as the status macOS reports after it.
        let asking = eventStore()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            asking.requestFullAccessToEvents { _, _ in done.resume() }
        }
        // A grant changes what EventKit sees: start from a fresh store.
        self.store = nil
        return await access()
        #else
        return .restricted
        #endif
    }

    /// The events overlapping the query's window, ordered by start, at most `limit`.
    public func events(_ query: SystemCalendarQuery) async -> [SystemCalendarEvent] {
        #if canImport(EventKit)
        let store = eventStore()
        var calendars: [EKCalendar]?
        if let ids = query.calendars {
            calendars = ids.compactMap { store.calendar(withIdentifier: $0) }
            if calendars?.isEmpty == true { return [] }
        }
        let predicate = store.predicateForEvents(
            withStart: Date(timeIntervalSince1970: query.from / 1000),
            end: Date(timeIntervalSince1970: query.to / 1000),
            calendars: calendars
        )
        let events = store.events(matching: predicate).sorted { lhs, rhs in
            lhs.startDate == rhs.startDate ? lhs.isAllDay && !rhs.isAllDay : lhs.startDate < rhs.startDate
        }
        return events.prefix(query.limit).map(Self.event)
        #else
        return []
        #endif
    }

    #if canImport(EventKit)
    private static func event(_ event: EKEvent) -> SystemCalendarEvent {
        let start = event.startDate.timeIntervalSince1970 * 1000
        let end = event.endDate.timeIntervalSince1970 * 1000
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return SystemCalendarEvent(
            id: "\(identifier)@\(Int64(start))",
            title: event.title ?? "",
            start: start,
            end: end,
            allDay: event.isAllDay,
            calendar: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            color: hex(event.calendar?.cgColor),
            location: event.location
        )
    }
    #endif

    /// `#rrggbb` in sRGB; Calendar's default blue when the calendar has no color.
    static func hex(_ color: CGColor?) -> String {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "#1badf8" }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", channel(srgb.redComponent), channel(srgb.greenComponent), channel(srgb.blueComponent))
    }
}
