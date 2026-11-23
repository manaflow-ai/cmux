@testable import CmuxMobileFeed
import Foundation
import Testing

/// The Feed's day separators: which local day an event belongs to, how a day
/// is named, and how the list's day sections follow a live change.
@Suite struct FeedDaysTests {
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    static func date(_ text: String, _ zone: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar(zone)
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    static let la = "America/Los_Angeles"

    // MARK: Bucketing

    @Test func midnightSplitsTwoEventsAMinuteApart() {
        let rows = [(id: "after", date: Self.date("2026-11-23 00:00", Self.la)), (id: "before", date: Self.date("2026-11-22 23:59", Self.la))]
        let groups = FeedDays.groups(rows, calendar: Self.calendar(Self.la))
        #expect(groups.map(\.ids) == [["after"], ["before"]])
        #expect(groups.map(\.section.day) == [Self.date("2026-11-23 00:00", Self.la), Self.date("2026-11-22 00:00", Self.la)])
    }

    /// The same two instants are one day in another time zone: the day is the phone's, not UTC's.
    @Test func theDayIsTheCalendarsTimeZones() {
        let rows = [(id: "after", date: Self.date("2026-11-23 00:00", Self.la)), (id: "before", date: Self.date("2026-11-22 23:59", Self.la))]
        #expect(FeedDays.groups(rows, calendar: Self.calendar("UTC")).map(\.ids) == [["after", "before"]])
        // 07:59 and 08:00 UTC straddle Tokyo's 17:00, still one day there; LA's evening is Tokyo's next day.
        let evening = [(id: "a", date: Self.date("2026-11-22 20:00", Self.la)), (id: "b", date: Self.date("2026-11-22 06:00", Self.la))]
        #expect(FeedDays.groups(evening, calendar: Self.calendar(Self.la)).count == 1)
        #expect(FeedDays.groups(evening, calendar: Self.calendar("Asia/Tokyo")).count == 2)
    }

    /// A day with a clock change is 23 or 25 hours long: its events stay one day, the next day's are not pulled in.
    @Test func aClockChangeDayIsOneDay() {
        let spring = [
            (id: "next", date: Self.date("2026-03-09 00:10", Self.la)),
            (id: "late", date: Self.date("2026-03-08 23:50", Self.la)),
            (id: "early", date: Self.date("2026-03-08 00:10", Self.la)),
            (id: "previous", date: Self.date("2026-03-07 23:50", Self.la)),
        ]
        #expect(FeedDays.groups(spring, calendar: Self.calendar(Self.la)).map(\.ids) == [["next"], ["late", "early"], ["previous"]])
        let fall = [
            (id: "next", date: Self.date("2026-11-02 00:10", Self.la)),
            (id: "late", date: Self.date("2026-11-01 23:50", Self.la)),
            (id: "early", date: Self.date("2026-11-01 00:10", Self.la)),
        ]
        #expect(FeedDays.groups(fall, calendar: Self.calendar(Self.la)).map(\.ids) == [["next"], ["late", "early"]])
    }

    /// Events out of time order never give the list the same section twice.
    @Test func aDaySeenAgainIsAnotherRun() {
        let rows = [
            (id: "a", date: Self.date("2026-11-23 10:00", Self.la)),
            (id: "b", date: Self.date("2026-11-22 10:00", Self.la)),
            (id: "c", date: Self.date("2026-11-23 09:00", Self.la)),
        ]
        let groups = FeedDays.groups(rows, calendar: Self.calendar(Self.la))
        #expect(groups.map(\.ids) == [["a"], ["b"], ["c"]])
        #expect(Set(groups.map(\.section)).count == 3)
        #expect(groups.map(\.section.run) == [0, 0, 1])
    }

    /// A stack's fold line has no time: it stays under its event, and the stack's older events open their own day.
    @Test func aRowWithNoTimeStaysInTheDayOfTheRowBefore() {
        let rows: [(id: String, date: Date?)] = [
            (id: "head", date: Self.date("2026-11-23 00:05", Self.la)),
            (id: "fold", date: nil),
            (id: "older", date: Self.date("2026-11-22 23:55", Self.la)),
        ]
        let groups = FeedDays.groups(carrying: rows, calendar: Self.calendar(Self.la))
        #expect(groups.map(\.ids) == [["head", "fold"], ["older"]])
        #expect(groups.map(\.section.run) == [0, 0])
    }

    @Test func noEventsNoSections() {
        #expect(FeedDays.groups([(id: String, date: Date)](), calendar: Self.calendar(Self.la)).isEmpty)
    }

    // MARK: Naming

    @Test func aDayIsNamedRelativeToToday() {
        let calendar = Self.calendar(Self.la)
        let today = Self.date("2026-11-23 00:00", Self.la) // a Monday
        func name(_ day: String) -> FeedDayName { FeedDayName(day: Self.date("\(day) 00:00", Self.la), today: today, calendar: calendar) }
        #expect(name("2026-11-23") == .today)
        #expect(name("2026-11-22") == .yesterday)
        #expect(name("2026-11-21") == .weekday)
        #expect(name("2026-11-17") == .weekday)
        // A week back is today's own weekday: the date says which Monday.
        #expect(name("2026-11-16") == .date(year: false))
        #expect(name("2026-01-02") == .date(year: false))
        #expect(name("2025-12-31") == .date(year: true))
        // A day after today (a Mac's clock ahead of the phone's): the date, never a weekday.
        #expect(name("2026-11-24") == .date(year: false))
    }

    /// Yesterday is the calendar day before, however few hours ago (00:05 today, 23:55 yesterday).
    @Test func yesterdayIsTheDayBeforeNotADayAgo() {
        let calendar = Self.calendar(Self.la)
        var bucketer = FeedDayBucketer(calendar: calendar)
        let today = bucketer.day(of: Self.date("2026-11-23 00:05", Self.la))
        let event = bucketer.day(of: Self.date("2026-11-22 23:55", Self.la))
        #expect(FeedDayName(day: event, today: today, calendar: calendar) == .yesterday)
        // Across the fall clock change (a 25 hour day) too.
        let after = bucketer.day(of: Self.date("2026-11-02 12:00", Self.la))
        let changeDay = bucketer.day(of: Self.date("2026-11-01 00:30", Self.la))
        #expect(FeedDayName(day: changeDay, today: after, calendar: calendar) == .yesterday)
    }

    @Test func labelsAreTheSystemsInThePersonsLanguage() {
        let calendar = Self.calendar(Self.la)
        let today = Self.date("2026-11-23 00:00", Self.la)
        func day(_ text: String) -> Date { Self.date("\(text) 00:00", Self.la) }
        let english = FeedDayLabeler(calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(english.text(day: today, today: today) == "Today")
        #expect(english.text(day: day("2026-11-22"), today: today) == "Yesterday")
        #expect(english.text(day: day("2026-11-21"), today: today) == "Saturday")
        #expect(english.text(day: day("2026-11-12"), today: today) == "Nov 12")
        #expect(english.text(day: day("2025-11-12"), today: today) == "Nov 12, 2025")
        let german = FeedDayLabeler(calendar: calendar, locale: Locale(identifier: "de_DE"))
        #expect(german.text(day: today, today: today) == "Heute")
        #expect(german.text(day: day("2026-11-22"), today: today) == "Gestern")
        #expect(german.text(day: day("2026-11-21"), today: today) == "Samstag")
        let spanish = FeedDayLabeler(calendar: calendar, locale: Locale(identifier: "es_ES"))
        #expect(spanish.text(day: today, today: today) == "Hoy")
        #expect(spanish.text(day: day("2026-11-21"), today: today) == "Sábado")
    }

    @Test func todayAtTheTopHasNoLabel() {
        let today = Self.date("2026-11-23 00:00", Self.la), yesterday = Self.date("2026-11-22 00:00", Self.la)
        #expect(!FeedDays.showsLabel(FeedDaySection(day: today), isFirst: true, today: today))
        #expect(FeedDays.showsLabel(FeedDaySection(day: yesterday), isFirst: true, today: today))
        #expect(FeedDays.showsLabel(FeedDaySection(day: yesterday), isFirst: false, today: today))
        // Today under a newer section (an event dated tomorrow) says so.
        #expect(FeedDays.showsLabel(FeedDaySection(day: today), isFirst: false, today: today))
        #expect(!FeedDays.showsLabel(.undated, isFirst: true, today: today))
    }

    // MARK: Section edits

    static let d1 = FeedDaySection(day: Date(timeIntervalSince1970: 300_000))
    static let d2 = FeedDaySection(day: Date(timeIntervalSince1970: 200_000))
    static let d3 = FeedDaySection(day: Date(timeIntervalSince1970: 100_000))

    /// The edit as the diffable snapshot applies it (FeedListController.edit).
    static func apply(_ edit: FeedDayEdit, to old: [FeedDayGroup]) -> [FeedDayGroup] {
        var groups = old.map { FeedDayGroup(section: $0.section, ids: $0.ids.filter { !edit.removed.contains($0) }) }
        for added in edit.addedSections {
            let index = added.after.map { after in groups.firstIndex { $0.section == after }! + 1 } ?? 0
            groups.insert(FeedDayGroup(section: added.section, ids: []), at: index)
        }
        for insert in edit.inserts {
            let section = groups.firstIndex { $0.section == insert.section }!
            if let before = insert.before {
                groups[section].ids.insert(contentsOf: insert.ids, at: groups[section].ids.firstIndex(of: before)!)
            } else {
                groups[section].ids.append(contentsOf: insert.ids)
            }
        }
        groups.removeAll { edit.removedSections.contains($0.section) }
        return groups
    }

    @Test func aLiveEventJoinsItsDay() throws {
        let old = [FeedDayGroup(section: Self.d2, ids: ["a", "b"]), FeedDayGroup(section: Self.d3, ids: ["c"])]
        let new = [FeedDayGroup(section: Self.d2, ids: ["n", "a", "b"]), FeedDayGroup(section: Self.d3, ids: ["c"])]
        let edit = try #require(FeedDayEdit(old: old, new: new))
        #expect(edit.addedSections.isEmpty && edit.removedSections.isEmpty && edit.removed.isEmpty)
        #expect(edit.inserts == [.init(ids: ["n"], section: Self.d2, before: "a")])
        #expect(Self.apply(edit, to: old) == new)
    }

    /// The first event of a new day opens its section above the others; it is never put in the day below it.
    @Test func theFirstEventOfADayOpensItsSection() throws {
        let old = [FeedDayGroup(section: Self.d2, ids: ["a"]), FeedDayGroup(section: Self.d3, ids: ["c"])]
        let new = [FeedDayGroup(section: Self.d1, ids: ["n1", "n2"]), FeedDayGroup(section: Self.d2, ids: ["a"]), FeedDayGroup(section: Self.d3, ids: ["c"])]
        let edit = try #require(FeedDayEdit(old: old, new: new))
        #expect(edit.addedSections == [.init(section: Self.d1, after: nil)])
        #expect(edit.inserts == [.init(ids: ["n1", "n2"], section: Self.d1, before: nil)])
        #expect(Self.apply(edit, to: old) == new)
    }

    @Test func olderEventsFromDiskAppendAndOpenDays() throws {
        let old = [FeedDayGroup(section: Self.d1, ids: ["a"]), FeedDayGroup(section: Self.d2, ids: ["b"])]
        let new = [FeedDayGroup(section: Self.d1, ids: ["a"]), FeedDayGroup(section: Self.d2, ids: ["b", "o1"]), FeedDayGroup(section: Self.d3, ids: ["o2", "o3"])]
        let edit = try #require(FeedDayEdit(old: old, new: new))
        #expect(edit.addedSections == [.init(section: Self.d3, after: Self.d2)])
        #expect(edit.inserts == [.init(ids: ["o1"], section: Self.d2, before: nil), .init(ids: ["o2", "o3"], section: Self.d3, before: nil)])
        #expect(Self.apply(edit, to: old) == new)
    }

    @Test func aDaysLastEventDoneClosesItsSection() throws {
        let old = [FeedDayGroup(section: Self.d1, ids: ["a"]), FeedDayGroup(section: Self.d2, ids: ["b"]), FeedDayGroup(section: Self.d3, ids: ["c", "d"])]
        let new = [FeedDayGroup(section: Self.d1, ids: ["a"]), FeedDayGroup(section: Self.d3, ids: ["c"])]
        let edit = try #require(FeedDayEdit(old: old, new: new))
        #expect(edit.removed == ["b", "d"])
        #expect(edit.removedSections == [Self.d2])
        #expect(edit.inserts.isEmpty && edit.addedSections.isEmpty)
        #expect(Self.apply(edit, to: old) == new)
    }

    @Test func mixedInsertsAndRemovalsAcrossDays() throws {
        let old = [FeedDayGroup(section: Self.d2, ids: ["a", "b", "c"]), FeedDayGroup(section: Self.d3, ids: ["d"])]
        let new = [FeedDayGroup(section: Self.d1, ids: ["n"]), FeedDayGroup(section: Self.d2, ids: ["a", "x", "c", "y"]), FeedDayGroup(section: Self.d3, ids: ["z", "d"])]
        let edit = try #require(FeedDayEdit(old: old, new: new))
        #expect(Self.apply(edit, to: old) == new)
    }

    /// A kept event in another day (its time changed, or the time zone did), or a re-sort: the sections are rebuilt.
    @Test func aRowThatChangesDayRebuilds() {
        let old = [FeedDayGroup(section: Self.d2, ids: ["a", "b"])]
        #expect(FeedDayEdit(old: old, new: [FeedDayGroup(section: Self.d1, ids: ["a"]), FeedDayGroup(section: Self.d2, ids: ["b"])]) == nil)
        #expect(FeedDayEdit(old: old, new: [FeedDayGroup(section: Self.d2, ids: ["b", "a"])]) == nil)
    }
}
