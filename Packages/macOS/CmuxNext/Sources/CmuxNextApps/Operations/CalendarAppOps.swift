#if canImport(CCmuxSystemCalendarFFI)
import CCmuxSystemCalendarFFI
#endif
#if canImport(EventKit)
import CoreGraphics
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
    /// The calendar's color as `#rrggbb` in sRGB, when it has one.
    public var color: String?

    /// Creates a record from an occurrence's fields, as EventKit gives them.
    public init(id: String, title: String, start: Date, end: Date, allDay: Bool, calendar: String,
                location: String? = nil, url: String? = nil, color: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
        self.url = url
        self.color = color
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
/// The params, the window and the answer are Rust (cmux-app-ffi `src/system_calendar.rs`); this
/// type keeps what needs EventKit: the access status, the prompt and reading the occurrences.
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

    public var families: Set<String> { ["system_calendar"] }

    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.params == .null || request.params.objectValue != nil else { throw Self.invalid("\(request.op) takes an object") }
        switch request.op {
        case "system_calendar.events":
            // The params, the window and the answer are Rust's (cmux-app-ffi src/system_calendar.rs).
            let window = try Self.call("window", ["params": request.params, "now": .number(now().timeIntervalSince1970)])
            if let error = window["error"] {
                throw AppHostCapabilityError(code: error["code"]?.stringValue ?? "invalid_params", message: error["message"]?.stringValue ?? "")
            }
            guard let start = window["start"]?.numberValue, let end = window["end"]?.numberValue,
                  let days = window["days"], let limit = window["limit"] else { throw .unsupported(request.op) }
            let access = await source.access()
            let records = access == .granted
                ? await source.events(from: Date(timeIntervalSince1970: start), to: Date(timeIntervalSince1970: end)) : []
            return try Self.call("answer", [
                "access": .string(access.rawValue), "now": .number(start), "days": days, "limit": limit,
                "records": .array(records.map(\.json)),
            ])
        case "system_calendar.request_access":
            return ["access": .string(await source.requestAccess().rawValue)]
        default:
            throw .unsupported(request.op)
        }
    }

    /// One op of `cmux_system_calendar_call`; `unsupported` where the app FFI is not linked.
    static func call(_ op: String, _ request: [String: AppJSON]) throws(AppHostCapabilityError) -> AppJSON {
        #if canImport(CCmuxSystemCalendarFFI)
        guard let body = try? JSONEncoder().encode(AppJSON.object(request)) else { throw .unsupported("system_calendar.\(op)") }
        var out = CmuxSystemCalendarBytes(ptr: nil, len: 0)
        let code = body.withUnsafeBytes { raw in
            op.withCString { cmux_system_calendar_call($0, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &out) }
        }
        defer { cmux_system_calendar_bytes_free(out) }
        guard code == CMUX_SYSTEM_CALENDAR_OK, let bytes = out.ptr,
              let reply = try? JSONDecoder().decode(AppJSON.self, from: Data(bytes: bytes, count: out.len))
        else { throw .unsupported("system_calendar.\(op)") }
        return reply
        #else
        throw .unsupported("system_calendar.\(op)")
        #endif
    }

    static func invalid(_ message: String) -> AppHostCapabilityError {
        AppHostCapabilityError(code: "invalid_params", message: message)
    }
}

nonisolated extension CalendarEventRecord {
    /// The record as `cmux_system_calendar_call`'s `answer` reads it: times in seconds since 1970.
    var json: AppJSON {
        var record: [String: AppJSON] = [
            "id": .string(id), "title": .string(title), "start": .number(start.timeIntervalSince1970),
            "end": .number(end.timeIntervalSince1970), "allDay": .bool(allDay), "calendar": .string(calendar),
        ]
        if let location { record["location"] = .string(location) }
        if let url { record["url"] = .string(url) }
        if let color { record["color"] = .string(color) }
        return .object(record)
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

    /// The calendar's color as `#rrggbb` in sRGB, or nil when it has none or will not convert.
    nonisolated static func hex(_ color: CGColor?) -> String? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let srgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count >= 3 else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", channel(parts[0]), channel(parts[1]), channel(parts[2]))
    }

    private nonisolated static func record(_ event: EKEvent) -> CalendarEventRecord {
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        return CalendarEventRecord(
            id: "\(base)@\(Int64((event.startDate.timeIntervalSince1970 * 1_000).rounded()))",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            allDay: event.isAllDay,
            calendar: event.calendar?.title ?? "",
            location: event.location,
            url: event.url?.absoluteString,
            color: hex(event.calendar?.cgColor)
        )
    }
}
#endif
