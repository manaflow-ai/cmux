#if canImport(EventKit)
import EventKit
#endif
public import Foundation

/// Whether cmux may read the person's calendar, as `system_calendar.*` answers it (`CmuxCalendarAccess`).
public nonisolated enum CalendarAccess: String, Sendable, Equatable {
    /// Full access: events can be read.
    case granted
    /// The person said no (or gave write-only access, which reads nothing).
    case denied
    /// A policy (Screen Time, a profile) keeps the app from asking.
    case restricted
    /// The person has not been asked yet.
    case notDetermined
    /// No system calendar here (not macOS, no EventKit).
    case unavailable
}

/// One event occurrence from the system calendar, before it is capped and sent to an app.
public nonisolated struct CalendarEventRecord: Sendable, Equatable {
    /// Stable for this occurrence: a recurring event's occurrences differ by start.
    public var id: String
    /// The event title (empty when it has none).
    public var title: String
    /// When it starts.
    public var start: Date
    /// When it ends.
    public var end: Date
    /// An all-day event.
    public var allDay: Bool
    /// The calendar's title.
    public var calendar: String
    /// Where it is, as written in the event.
    public var location: String?
    /// The event's link.
    public var url: String?

    /// Creates a record from an occurrence's fields, as EventKit gives them.
    public init(id: String, title: String, start: Date, end: Date, allDay: Bool, calendar: String,
                location: String? = nil, url: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
        self.url = url
    }
}

/// The system calendar behind `system_calendar.*`: EventKit in the app, a fake in tests.
public nonisolated protocol CalendarEventSource: Sendable {
    /// The current access status. Never prompts.
    func access() async -> CalendarAccess
    /// Shows the system prompt when the person has not answered it, then the access status.
    func requestAccess() async -> CalendarAccess
    /// The event occurrences overlapping `start..<end` in every event calendar; only called with access.
    func events(from start: Date, to end: Date) async -> [CalendarEventRecord]
}

/// The `system_calendar` family (`cmux.system_calendar.*`; not the Cloud's Google `calendar.*` ops): the person's system calendar, which only the Mac app
/// (holding the calendar permission and its usage strings) can read; the daemon routes the family here.
///
/// - `system_calendar.events {days?, limit?}` (read, scope `system_calendar:read`): `{access, events}`. Events from
///   now (in progress ones too: `end > now`) through now + `days` (1-31, default 7), sorted by start,
///   at most `limit` (1-50, default 20). Never prompts: without full access, `events` is empty.
/// - `system_calendar.request_access {}` (mutation, scope `system_calendar:read`, a gesture: `needs_gesture` in
///   cmux-app-manifest): shows the system prompt if the person has not answered it; `{access}`.
public nonisolated struct CalendarAppOps: AppHostCapabilityHandler {
    let source: any CalendarEventSource
    let now: @Sendable () -> Date

    /// - Parameters:
    ///   - source: The calendar; EventKit by default.
    ///   - now: The clock the window starts at.
    public init(source: any CalendarEventSource = CalendarAppOps.systemSource(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.now = now
    }

    /// The system calendar: EventKit where it exists, else a source that answers `unavailable`.
    public static func systemSource() -> any CalendarEventSource {
        #if canImport(EventKit)
        return EventKitCalendarSource()
        #else
        return UnavailableCalendarSource()
        #endif
    }

    static let defaultDays = 7
    static let maxDays = 31
    static let defaultLimit = 20
    static let maxLimit = 50
    static let maxText = 200
    static let maxURL = 2_000

    public var families: Set<String> { ["system_calendar"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.params == .null || request.params.objectValue != nil else { throw Self.invalid("\(request.op) takes an object") }
        switch request.op {
        case "system_calendar.events":
            let days = try Self.integer(request.params, "days", default: Self.defaultDays, in: 1...Self.maxDays)
            let limit = try Self.integer(request.params, "limit", default: Self.defaultLimit, in: 1...Self.maxLimit)
            let access = await source.access()
            guard access == .granted else { return Self.answer(access: access, records: [], now: now(), days: days, limit: limit) }
            let start = now()
            let end = start.addingTimeInterval(TimeInterval(days) * 86_400)
            let records = await source.events(from: start, to: end)
            return Self.answer(access: access, records: records, now: start, days: days, limit: limit)
        case "system_calendar.request_access":
            return ["access": .string(await source.requestAccess().rawValue)]
        default:
            throw .unsupported(request.op)
        }
    }

    /// `system_calendar.events`' answer: the occurrences with `end > now` and `start < now + days`, sorted by
    /// start (then end, title, id), at most `limit`, text capped. No events unless `access` is granted.
    static func answer(access: CalendarAccess, records: [CalendarEventRecord], now: Date, days: Int, limit: Int) -> AppJSON {
        guard access == .granted else { return ["access": .string(access.rawValue), "events": []] }
        let end = now.addingTimeInterval(TimeInterval(days) * 86_400)
        let kept = records
            .filter { $0.end > now && $0.start < end }
            .sorted { a, b in
                if a.start != b.start { return a.start < b.start }
                if a.end != b.end { return a.end < b.end }
                if a.title != b.title { return a.title < b.title }
                return a.id < b.id
            }
            .prefix(limit)
        return ["access": .string(access.rawValue), "events": .array(kept.map { Self.json($0) })]
    }

    /// One event as the app sees it (`CmuxCalendarEvent`): epoch ms, capped text, no empty optionals.
    static func json(_ record: CalendarEventRecord) -> AppJSON {
        var event: [String: AppJSON] = [
            "id": .string(String(record.id.prefix(maxText))),
            "title": .string(String(record.title.prefix(maxText))),
            "start": .number(milliseconds(record.start)),
            "end": .number(milliseconds(record.end)),
            "allDay": .bool(record.allDay),
            "calendar": .string(String(record.calendar.prefix(maxText))),
        ]
        if let location = record.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            event["location"] = .string(String(location.prefix(maxText)))
        }
        if let url = record.url, !url.isEmpty, url.count <= maxURL { event["url"] = .string(url) }
        return .object(event)
    }

    static func milliseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 * 1_000).rounded()
    }

    /// The integer param `key`, `fallback` when absent or null; `invalid_params` outside `range`.
    static func integer(_ params: AppJSON, _ key: String, default fallback: Int, in range: ClosedRange<Int>) throws(AppHostCapabilityError) -> Int {
        guard let value = params[key], value != .null else { return fallback }
        guard let number = value.numberValue, number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            throw invalid("\(key) is a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(number)
    }

    static func invalid(_ message: String) -> AppHostCapabilityError {
        AppHostCapabilityError(code: "invalid_params", message: message)
    }
}

/// A calendar source where there is no system calendar.
nonisolated struct UnavailableCalendarSource: CalendarEventSource {
    func access() async -> CalendarAccess { .unavailable }
    func requestAccess() async -> CalendarAccess { .unavailable }
    func events(from start: Date, to end: Date) async -> [CalendarEventRecord] { [] }
}

#if canImport(EventKit)
/// The system calendar through EventKit. The store is made on the first read with access (a store
/// made before access was granted lists no calendars), off the main thread.
actor EventKitCalendarSource: CalendarEventSource {
    private var store: EKEventStore?

    func access() async -> CalendarAccess {
        Self.access(of: EKEventStore.authorizationStatus(for: .event))
    }

    func requestAccess() async -> CalendarAccess {
        let current = await access()
        guard current == .notDetermined else { return current }
        // The package deploys to macOS 14, where requestFullAccessToEvents always exists.
        let asking = EKEventStore()
        _ = try? await asking.requestFullAccessToEvents()
        store = nil
        return await access()
    }

    func events(from start: Date, to end: Date) async -> [CalendarEventRecord] {
        let store = self.store ?? EKEventStore()
        self.store = store
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.record)
    }

    /// `system_calendar.*`'s access string for an EventKit status: only full access reads events.
    nonisolated static func access(of status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    private nonisolated static func record(_ event: EKEvent) -> CalendarEventRecord {
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        return CalendarEventRecord(
            id: "\(base)@\(Int64(CalendarAppOps.milliseconds(event.startDate)))",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            allDay: event.isAllDay,
            calendar: event.calendar?.title ?? "",
            location: event.location,
            url: event.url?.absoluteString
        )
    }
}
#endif
