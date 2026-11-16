import CmuxNextApps
import Foundation
import Testing

/// `system_calendar.*`: the Mac's calendars for apps, read from EventKit (a fake store here).
@MainActor
struct SystemCalendarAppOpsTests {
    @Test func aGrantedReadShapesEventsForTheApp() async throws {
        let store = FakeCalendarStore(access: .granted, events: [
            .init(id: "a@3600000", title: "Standup", start: 3_600_000, end: 5_400_000, allDay: false,
                  calendar: "work", calendarTitle: "Work", color: "#1badf8", location: "Room 4"),
            .init(id: "b@0", title: "Holiday", start: 0, end: 86_400_000, allDay: true,
                  calendar: "home", calendarTitle: "Home", color: "#34c759"),
        ])
        let ops = SystemCalendarAppOps(store: store) {}
        let reply = try await ops.handle(request("system_calendar.events.list", ["from": 0, "to": 86_400_000, "limit": 1]))
        #expect(reply == ["access": "granted", "events": [
            ["id": "a@3600000", "title": "Standup", "start": 3_600_000, "end": 5_400_000, "all_day": false,
             "calendar": "work", "calendar_title": "Work", "color": "#1badf8", "location": "Room 4"],
        ]])
        #expect(await store.queries.first?.limit == 1)
    }

    @Test func aReadNeverPromptsAndCarriesNoEventsUntilGranted() async throws {
        for access in [SystemCalendarAccess.notDetermined, .denied, .restricted] {
            let store = FakeCalendarStore(access: access, events: [])
            let ops = SystemCalendarAppOps(store: store) {}
            let reply = try await ops.handle(request("system_calendar.events.list", ["from": 0, "to": 1, "limit": 5]))
            #expect(reply == ["access": .string(access.rawValue), "events": []])
            #expect(await store.prompts == 0)
            #expect(await store.queries.isEmpty)
        }
    }

    @Test func accessRequestPromptsOnceThenOpensSettingsAfterARefusal() async throws {
        let store = FakeCalendarStore(access: .notDetermined, events: [], afterPrompt: .granted)
        let opened = OpenCount()
        let ops = SystemCalendarAppOps(store: store) { opened.count += 1 }
        #expect(try await ops.handle(request("system_calendar.access.request", [:])) == ["access": "granted"])
        #expect(await store.prompts == 1)

        let refused = FakeCalendarStore(access: .denied, events: [])
        let settings = SystemCalendarAppOps(store: refused) { opened.count += 1 }
        #expect(try await settings.handle(request("system_calendar.access.request", [:])) == ["access": "denied"])
        #expect(await refused.prompts == 0)
        #expect(opened.count == 1)
    }

    @Test func malformedParamsAndOtherOpsAreRefused() async {
        let ops = SystemCalendarAppOps(store: FakeCalendarStore(access: .granted, events: [])) {}
        for params: AppJSON in [.null, ["from": 5, "to": 1, "limit": 5], ["from": 0, "to": 1], ["from": 0, "to": 1, "limit": 5, "calendars": [1]]] {
            await #expect(throws: AppHostCapabilityError.self) {
                _ = try await ops.handle(request("system_calendar.events.list", params))
            }
        }
        do {
            _ = try await ops.handle(request("system_calendar.event.create", [:]))
            Issue.record("expected unsupported")
        } catch {
            #expect(error.code == "operation.unsupported")
        }
    }

    private func request(_ op: String, _ params: AppJSON) -> AppHostCapabilityRequest {
        AppHostCapabilityRequest(app: "cmux/calendar", op: op, params: params, origin: "user")
    }
}

private actor FakeCalendarStore: SystemCalendarStore {
    private var current: SystemCalendarAccess
    private let afterPrompt: SystemCalendarAccess?
    private let stored: [SystemCalendarEvent]
    private(set) var prompts = 0
    private(set) var queries: [SystemCalendarQuery] = []

    init(access: SystemCalendarAccess, events: [SystemCalendarEvent], afterPrompt: SystemCalendarAccess? = nil) {
        current = access
        stored = events
        self.afterPrompt = afterPrompt
    }

    func access() async -> SystemCalendarAccess { current }

    func requestAccess() async -> SystemCalendarAccess {
        prompts += 1
        if let afterPrompt { current = afterPrompt }
        return current
    }

    func events(_ query: SystemCalendarQuery) async -> [SystemCalendarEvent] {
        queries.append(query)
        return stored
    }
}

@MainActor private final class OpenCount {
    var count = 0
}
