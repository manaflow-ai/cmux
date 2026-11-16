import AppKit
import CmuxNextCompat
import Foundation

/// Serves the `system_calendar` family: the Mac's own calendars, read from
/// EventKit for apps that hold `system_calendar:read` (a calendar widget).
///
/// The daemon (`cmux-tui-core` `apps/system_calendar.rs`) has already checked
/// and normalized the params (`from`/`to` Unix ms at most 32 days apart, a
/// clamped `limit`, deduplicated `calendars`) and caches granted answers, so
/// this owner only reads EventKit and shapes the answer:
/// - `system_calendar.events.list {from, to, limit, calendars?}` ->
///   `{access, events: [{id, title, start, end, all_day, calendar,
///   calendar_title, color, location?}]}`. Never prompts: until the person
///   answers macOS's question it answers `access: "not_determined"` with no events.
/// - `system_calendar.access.request {}` -> `{access}`: asks macOS's Calendars
///   question when it was never asked; after a refusal macOS cannot ask again,
///   so it opens Privacy & Security > Calendars instead. The supervisor admits
///   it only inside a user gesture.
public nonisolated struct SystemCalendarAppOps: AppHostCapabilityHandler {
    private let store: any SystemCalendarStore
    private let openPrivacySettings: @MainActor @Sendable () -> Void

    /// The longest event title or location sent to an app, in characters.
    static let maximumText = 500

    /// The Privacy & Security pane for calendars.
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")

    /// The capability family supplied on the verified-app provider channel.
    public var families: Set<String> { ["system_calendar"] }

    /// Creates the handler.
    /// - Parameters:
    ///   - store: The calendar store (EventKit in the app, a fake in tests).
    ///   - openPrivacySettings: Opens Privacy & Security > Calendars.
    public init(store: any SystemCalendarStore,
                openPrivacySettings: @escaping @MainActor @Sendable () -> Void) {
        self.store = store
        self.openPrivacySettings = openPrivacySettings
    }

    /// The app's handler: EventKit, and System Settings opened in the background.
    public static func eventKit() -> SystemCalendarAppOps {
        SystemCalendarAppOps(store: EventKitCalendarStore()) {
            guard let url = privacySettingsURL else { return }
            NSWorkspace.shared.openInBackground(url)
        }
    }

    /// Answers `events.list` and `access.request`.
    /// - Parameter request: The supervisor-admitted call.
    /// - Returns: The op's answer before the ABI's `{value}` envelope.
    /// - Throws: `operation.unsupported` for other ops, `validation.invalid` for malformed params.
    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        switch request.op {
        case "system_calendar.events.list":
            let query = try SystemCalendarQuery(params: request.params)
            let access = await store.access()
            guard access == .granted else { return ["access": .string(access.rawValue), "events": []] }
            let events = await store.events(query)
            return ["access": .string(access.rawValue), "events": .array(events.prefix(query.limit).map(Self.json))]
        case "system_calendar.access.request":
            let access = await store.access()
            switch access {
            case .notDetermined:
                return ["access": .string(await store.requestAccess().rawValue)]
            case .denied:
                await openPrivacySettings()
                return ["access": .string(access.rawValue)]
            case .granted, .restricted:
                return ["access": .string(access.rawValue)]
            }
        default:
            throw .unsupported(request.op)
        }
    }

    static func json(_ event: SystemCalendarEvent) -> AppJSON {
        var out: [String: AppJSON] = [
            "id": .string(event.id),
            "title": .string(String(event.title.prefix(maximumText))),
            "start": .number(event.start),
            "end": .number(event.end),
            "all_day": .bool(event.allDay),
            "calendar": .string(event.calendar),
            "calendar_title": .string(String(event.calendarTitle.prefix(maximumText))),
            "color": .string(event.color),
        ]
        if let location = event.location, !location.isEmpty { out["location"] = .string(String(location.prefix(maximumText))) }
        return .object(out)
    }
}

/// Whether this Mac lets cmux read its calendars (the wire's `access`).
public nonisolated enum SystemCalendarAccess: String, Sendable {
    case granted
    case notDetermined = "not_determined"
    case denied
    case restricted
}

/// One read of `system_calendar.events.list`, after the daemon normalized it.
public nonisolated struct SystemCalendarQuery: Sendable, Equatable {
    /// The window's start, Unix milliseconds.
    public var from: Double
    /// The window's end, Unix milliseconds.
    public var to: Double
    /// The most events to answer.
    public var limit: Int
    /// Calendar ids to read, or nil for every calendar.
    public var calendars: [String]?

    /// Parses the daemon-normalized params; anything else is `validation.invalid`.
    /// - Parameter params: `{from, to, limit, calendars?}`.
    public init(params: AppJSON) throws(AppHostCapabilityError) {
        guard let from = params["from"]?.numberValue, let to = params["to"]?.numberValue, to > from,
              let limit = params["limit"]?.numberValue, limit >= 1, limit.rounded() == limit else {
            throw AppHostCapabilityError(code: "validation.invalid", message: "Expected from, to and limit")
        }
        self.from = from
        self.to = to
        self.limit = Int(min(limit, 200))
        if let list = params["calendars"] {
            guard let ids = list.arrayValue?.compactMap(\.stringValue), ids.count == list.arrayValue?.count else {
                throw AppHostCapabilityError(code: "validation.invalid", message: "Expected calendars to be a list of ids")
            }
            calendars = ids
        }
    }
}

/// One event as an app sees it.
public nonisolated struct SystemCalendarEvent: Sendable, Equatable {
    /// Stable per occurrence: the event's identifier and its start.
    public var id: String
    /// The event's title.
    public var title: String
    /// Start, Unix milliseconds.
    public var start: Double
    /// End, Unix milliseconds.
    public var end: Double
    /// Whether it is an all-day event.
    public var allDay: Bool
    /// The calendar's id.
    public var calendar: String
    /// The calendar's name.
    public var calendarTitle: String
    /// The calendar's color, `#rrggbb`.
    public var color: String
    /// Where it happens, if set.
    public var location: String?

    /// Creates an event.
    public init(id: String, title: String, start: Double, end: Double, allDay: Bool,
                calendar: String, calendarTitle: String, color: String, location: String? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.calendarTitle = calendarTitle
        self.color = color
        self.location = location
    }
}

/// The calendar store behind `system_calendar`: EventKit in the app.
public nonisolated protocol SystemCalendarStore: Sendable {
    /// The current access, without asking.
    func access() async -> SystemCalendarAccess
    /// Asks macOS's Calendars question and answers the access after it.
    func requestAccess() async -> SystemCalendarAccess
    /// The events of `query`'s window, ordered by start (only while granted).
    func events(_ query: SystemCalendarQuery) async -> [SystemCalendarEvent]
}
