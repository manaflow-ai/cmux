#if canImport(EventKit)
import EventKit
#endif
@testable import CmuxNextApps
import Foundation
import Testing

/// `system_calendar.events` and `system_calendar.request_access` (`cmux.system_calendar.*`): the person's system calendar,
/// read through a fake source so the window, sort, cap and access mapping are checked without EventKit.
@Suite(.timeLimit(.minutes(1)))
nonisolated struct CalendarAppOpsTests {
    /// A calendar that answers a fixed status and events, and records what it was asked.
    private actor FakeCalendar: CalendarEventSource {
        var status: CalendarAccess
        var afterPrompt: CalendarAccess
        var records: [CalendarEventRecord]
        var prompts = 0
        var reads: [(Date, Date)] = []

        init(_ status: CalendarAccess, afterPrompt: CalendarAccess = .granted, records: [CalendarEventRecord] = []) {
            self.status = status
            self.afterPrompt = afterPrompt
            self.records = records
        }

        func access() async -> CalendarAccess { status }
        func requestAccess() async -> CalendarAccess {
            prompts += 1
            if status == .notDetermined { status = afterPrompt }
            return status
        }
        func events(from start: Date, to end: Date) async -> [CalendarEventRecord] {
            reads.append((start, end))
            return records
        }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: TimeInterval = 3_600

    static func event(_ id: String, at offset: TimeInterval, hours: TimeInterval = 1, title: String? = nil,
                      allDay: Bool = false, location: String? = nil, url: String? = nil, color: String? = nil) -> CalendarEventRecord {
        CalendarEventRecord(id: id, title: title ?? id, start: now.addingTimeInterval(offset),
                            end: now.addingTimeInterval(offset + hours * hour), allDay: allDay,
                            calendar: "Work", location: location, url: url, color: color)
    }

    private func ops(_ calendar: FakeCalendar) -> CalendarAppOps {
        let now = Self.now
        return CalendarAppOps(source: calendar, now: { now })
    }

    private func request(_ op: String, _ params: AppJSON = [:]) -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "local/widget", op: op, params: params, origin: "script")
    }

    private func ids(_ answer: AppJSON) -> [String] {
        (answer["events"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }

    @Test func eventsAreTheWindowFromNowSortedByStartAndCapped() async throws {
        let calendar = FakeCalendar(.granted, records: [
            Self.event("later", at: 5 * Self.hour),
            Self.event("ended", at: -3 * Self.hour, hours: 1),
            Self.event("inProgress", at: -Self.hour / 2),
            Self.event("soon", at: Self.hour),
            Self.event("pastWindow", at: 8 * 86_400),
            Self.event("tomorrow", at: 86_400),
        ])
        let answer = try await ops(calendar).handle(request("system_calendar.events", ["days": 2, "limit": 3]))
        #expect(answer["access"]?.stringValue == "granted")
        #expect(ids(answer) == ["inProgress", "soon", "later"])
        let reads = await calendar.reads
        #expect(reads.count == 1)
        #expect(reads.first?.0 == Self.now)
        #expect(reads.first?.1 == Self.now.addingTimeInterval(2 * 86_400))
    }

    @Test func theDefaultWindowIsSevenDaysAndTwentyEvents() async throws {
        let many = (0..<30).map { Self.event("e\(String(format: "%02d", $0))", at: TimeInterval($0) * Self.hour) }
        let calendar = FakeCalendar(.granted, records: many + [Self.event("day8", at: 7 * 86_400 + Self.hour)])
        let answer = try await ops(calendar).handle(request("system_calendar.events"))
        #expect(ids(answer).count == 20)
        #expect(ids(answer).first == "e00")
        let reads = await calendar.reads
        #expect(reads.first?.1 == Self.now.addingTimeInterval(7 * 86_400))
        let null = try await ops(calendar).handle(request("system_calendar.events", .null))
        #expect(ids(null).count == 20)
    }

    @Test func anEventIsSentInTheAppsShape() async throws {
        let long = String(repeating: "x", count: 500)
        let calendar = FakeCalendar(.granted, records: [
            Self.event("a", at: Self.hour, title: long, allDay: true, location: "  Room 4  ", url: "https://meet.example.com/a", color: "#1badf8"),
            Self.event("b", at: 2 * Self.hour, location: "   ", url: "https://x.example/" + long + long + long + long + long, color: "blue"),
        ])
        let answer = try await ops(calendar).handle(request("system_calendar.events"))
        let events = try #require(answer["events"]?.arrayValue)
        let first = try #require(events.first?.objectValue)
        #expect(first["title"]?.stringValue?.count == CalendarAppOps.maxText)
        #expect(first["start"]?.numberValue == (Self.now.timeIntervalSince1970 + Self.hour) * 1_000)
        #expect(first["end"]?.numberValue == (Self.now.timeIntervalSince1970 + 2 * Self.hour) * 1_000)
        #expect(first["allDay"]?.boolValue == true)
        #expect(first["calendar"]?.stringValue == "Work")
        #expect(first["location"]?.stringValue == "Room 4")
        #expect(first["url"]?.stringValue == "https://meet.example.com/a")
        #expect(first["color"]?.stringValue == "#1badf8")
        let second = try #require(events.last?.objectValue)
        #expect(!second.keys.contains("location"), "a blank location is left out")
        #expect(!second.keys.contains("url"), "an over-long link is left out")
        #expect(!second.keys.contains("color"), "a color not in #rrggbb form is left out")
        #expect(Set(second.keys) == ["id", "title", "start", "end", "allDay", "calendar"])
    }

    @Test func eventsNeverPromptAndAnswerTheStatusWithoutAccess() async throws {
        for status: CalendarAccess in [.notDetermined, .denied, .restricted, .unavailable] {
            let calendar = FakeCalendar(status, records: [Self.event("secret", at: Self.hour)])
            let answer = try await ops(calendar).handle(request("system_calendar.events"))
            #expect(answer["access"]?.stringValue == status.rawValue)
            #expect(answer["events"]?.arrayValue == [])
            #expect(await calendar.prompts == 0)
            #expect(await calendar.reads.isEmpty, "no read without access")
        }
    }

    @Test func requestAccessPromptsAndAnswersTheNewStatus() async throws {
        let calendar = FakeCalendar(.notDetermined, afterPrompt: .granted)
        let answer = try await ops(calendar).handle(request("system_calendar.request_access"))
        #expect(answer == ["access": "granted"])
        #expect(await calendar.prompts == 1)
        let denied = FakeCalendar(.notDetermined, afterPrompt: .denied)
        #expect(try await ops(denied).handle(request("system_calendar.request_access")) == ["access": "denied"])
    }

    @Test func badParamsAreRefusedBeforeTheCalendarIsRead() async {
        let calendar = FakeCalendar(.granted, records: [Self.event("a", at: Self.hour)])
        let ops = ops(calendar)
        for params: AppJSON in [["days": 0], ["days": 32], ["days": 1.5], ["days": "7"], ["limit": 0], ["limit": 51], ["limit": true], "x", [1]] {
            await #expect(throws: AppHostCapabilityError.self) { try await ops.handle(request("system_calendar.events", params)) }
        }
        #expect(await calendar.reads.isEmpty)
        do {
            _ = try await ops.handle(request("system_calendar.write"))
            Issue.record("expected unsupported")
        } catch {
            #expect(error.code == "operation.unsupported")
        }
    }

    @Test func theRouterSendsTheSystemCalendarFamilyToIt() {
        let router = AppHostCapabilities([CalendarAppOps(source: UnavailableCalendarSource())])
        for op in ["system_calendar.events", "system_calendar.request_access"] { #expect(router.handles(op)) }
        #expect(router.families.contains("system_calendar"))
    }

    #if canImport(EventKit)
    @Test func onlyFullAccessReadsEvents() {
        #expect(EventKitCalendarSource.access(of: .fullAccess) == .granted)
        #expect(EventKitCalendarSource.access(of: .writeOnly) == .denied)
        #expect(EventKitCalendarSource.access(of: .denied) == .denied)
        #expect(EventKitCalendarSource.access(of: .restricted) == .restricted)
        #expect(EventKitCalendarSource.access(of: .notDetermined) == .notDetermined)
    }
    #endif
}
