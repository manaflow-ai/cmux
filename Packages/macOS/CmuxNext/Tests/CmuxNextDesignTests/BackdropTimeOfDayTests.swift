@testable import CmuxNextDesign
import Foundation
import Testing

/// Auto-switching wallpaper by time of day (Leo, 2026-11-14: "the auto switching that macos does"):
/// sun events by the NOAA equations, and `appearance.backgroundSchedule` resolved in local time
/// across time zones and daylight saving changes.
@Suite struct BackdropTimeOfDayTests {
    static let sanFrancisco = BackdropLocation(latitude: 37.7749, longitude: -122.4194)
    static let tromso = BackdropLocation(latitude: 69.6496, longitude: 18.956)

    static func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    static func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    /// Minutes between `date` and the local clock time `hour:minute` of the same day.
    static func minutesOff(_ date: Date?, _ calendar: Calendar, _ hour: Int, _ minute: Int) throws -> Double {
        let date = try #require(date)
        let target = try #require(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date))
        return abs(date.timeIntervalSince(target)) / 60
    }

    /// NOAA Solar Calculator, San Francisco: 2026-06-21 sunrise 05:48, noon 13:12, sunset 20:35
    /// PDT; 2026-12-21 sunrise 07:21, noon 12:08, sunset 16:54 PST.
    @Test func sunTimesMatchNOAAWithinTwoMinutes() throws {
        let calendar = try Self.calendar("America/Los_Angeles")
        let june = Self.sanFrancisco.sunEvents(on: try Self.date(calendar, 2026, 6, 21), calendar: calendar)
        #expect(try Self.minutesOff(june.sunrise, calendar, 5, 48) <= 2)
        #expect(try Self.minutesOff(june.noon, calendar, 13, 12) <= 2)
        #expect(try Self.minutesOff(june.sunset, calendar, 20, 35) <= 2)
        let december = Self.sanFrancisco.sunEvents(on: try Self.date(calendar, 2026, 12, 21), calendar: calendar)
        #expect(try Self.minutesOff(december.sunrise, calendar, 7, 21) <= 2)
        #expect(try Self.minutesOff(december.noon, calendar, 12, 8) <= 2)
        #expect(try Self.minutesOff(december.sunset, calendar, 16, 54) <= 2)
        // Civil dawn comes before sunrise, dusk after sunset.
        #expect(try #require(december.dawn) < (try #require(december.sunrise)))
        #expect(try #require(december.dusk) > (try #require(december.sunset)))
        // At solar noon the sun is due south and highest: 90 - 37.77 + 23.44 in June.
        let high = Self.sanFrancisco.sunPosition(at: june.noon)
        #expect(abs(high.altitude - 75.7) < 0.5)
        #expect(abs(high.azimuth - 180) < 1)
    }

    /// Tromsø has polar night in December (no sunrise or sunset, but civil twilight at noon) and
    /// midnight sun in June (no sunset, no dusk).
    @Test func polarDaysSkipTheMissingEvents() throws {
        let calendar = try Self.calendar("Europe/Oslo")
        let winter = Self.tromso.sunEvents(on: try Self.date(calendar, 2026, 12, 21), calendar: calendar)
        #expect(winter.sunrise == nil && winter.sunset == nil)
        #expect(winter.dawn != nil && winter.dusk != nil)
        let summer = Self.tromso.sunEvents(on: try Self.date(calendar, 2026, 6, 21), calendar: calendar)
        #expect(summer.sunrise == nil && summer.sunset == nil && summer.dusk == nil)

        // A schedule's sunset entry is skipped that day: the morning picture holds into the night.
        let schedule = try #require(BackdropTimeOfDay.parse(["07:00": "day", "sunset": "night"]) { _ in true })
        let evening = try Self.date(calendar, 2026, 12, 21, 20)
        #expect(schedule.resolve(at: evening, location: Self.tromso, calendar: calendar).value == "day")
        // In San Francisco the same evening is night.
        let pacific = try Self.calendar("America/Los_Angeles")
        #expect(schedule.resolve(at: try Self.date(pacific, 2026, 12, 21, 20), location: Self.sanFrancisco, calendar: pacific).value == "night")
    }

    @Test func scheduleKeysParse() {
        #expect(BackdropTimeOfDay.when("07:00") == .clock(minutes: 420))
        #expect(BackdropTimeOfDay.when("9:05") == .clock(minutes: 545))
        #expect(BackdropTimeOfDay.when("sunset-30m") == .sun(.sunset, offset: -1_800))
        #expect(BackdropTimeOfDay.when("sunrise+1h") == .sun(.sunrise, offset: 3_600))
        #expect(BackdropTimeOfDay.when("dusk") == .sun(.dusk, offset: 0))
        for bad in ["24:00", "07:60", "7", "sunset-", "sunset+30s", "midnight", "Sunset", "sunrise+25h", "07:0", "٠٧:٠٠"] {
            #expect(BackdropTimeOfDay.when(bad) == nil, "\(bad)")
        }
    }

    /// Now's picture is the latest entry at or before now; before the first, yesterday's last; the
    /// next change is the following entry, in each zone's own local time.
    @Test(arguments: ["America/Los_Angeles", "Asia/Tokyo", "Australia/Lord_Howe"])
    func scheduleResolvesInLocalTime(zone: String) throws {
        let calendar = try Self.calendar(zone)
        let schedule = try #require(BackdropTimeOfDay.parse(["07:00": "morning", "12:30": "noon", "19:00": "night"]) { _ in true })
        let early = try Self.date(calendar, 2026, 5, 10, 5, 59)
        let (value, next) = schedule.resolve(at: early, location: nil, calendar: calendar)
        #expect(value == "night")
        #expect(next == (try Self.date(calendar, 2026, 5, 10, 7, 0)))
        #expect(schedule.resolve(at: try Self.date(calendar, 2026, 5, 10, 7, 0), location: nil, calendar: calendar).value == "morning")
        #expect(schedule.resolve(at: try Self.date(calendar, 2026, 5, 10, 12, 29), location: nil, calendar: calendar).value == "morning")
        let afternoon = schedule.resolve(at: try Self.date(calendar, 2026, 5, 10, 12, 30), location: nil, calendar: calendar)
        #expect(afternoon.value == "noon")
        #expect(afternoon.next == (try Self.date(calendar, 2026, 5, 10, 19, 0)))
        // Sun entries without a location are skipped; the clock entries still turn.
        let mixed = try #require(BackdropTimeOfDay.parse(["07:00": "day", "sunset": "night"]) { _ in true })
        #expect(mixed.resolve(at: try Self.date(calendar, 2026, 5, 10, 23), location: nil, calendar: calendar).value == "day")
    }

    /// Spring forward (Los Angeles 2026-03-08, 02:00 -> 03:00): 02:30 does not exist and fires at
    /// 03:00 PDT. Fall back (2026-11-01, 02:00 -> 01:00): 01:30 happens twice and fires the first time.
    @Test func daylightSavingGapsAndRepeats() throws {
        let calendar = try Self.calendar("America/Los_Angeles")
        let schedule = try #require(BackdropTimeOfDay.parse(["02:30": "late", "12:00": "day"]) { _ in true })
        let beforeGap = try Self.date(calendar, 2026, 3, 8, 1, 0)
        let spring = schedule.resolve(at: beforeGap, location: nil, calendar: calendar)
        #expect(spring.value == "day")
        // 03:00 PDT is 10:00 UTC.
        #expect(spring.next == Date(timeIntervalSince1970: 1_772_964_000))

        let fallSchedule = try #require(BackdropTimeOfDay.parse(["01:30": "late", "12:00": "day"]) { _ in true })
        let beforeRepeat = try Self.date(calendar, 2026, 11, 1, 0, 30)
        let fall = fallSchedule.resolve(at: beforeRepeat, location: nil, calendar: calendar)
        // The first 01:30 is PDT, 08:30 UTC.
        #expect(fall.next == Date(timeIntervalSince1970: 1_793_521_800))
        // After the second 01:30 (09:30 UTC) the picture does not turn again before noon.
        let afterRepeat = Date(timeIntervalSince1970: 1_793_525_400 + 60)
        let later = fallSchedule.resolve(at: afterRepeat, location: nil, calendar: calendar)
        #expect(later.value == "late")
        #expect(later.next == (try Self.date(calendar, 2026, 11, 1, 12, 0)))
    }

    /// Lord Howe Island moves its clocks half an hour (02:00 -> 02:30 on 2026-10-04): 02:15 fires at 02:30.
    @Test func halfHourDaylightSavingGap() throws {
        let calendar = try Self.calendar("Australia/Lord_Howe")
        let schedule = try #require(BackdropTimeOfDay.parse(["02:15": "late", "12:00": "day"]) { _ in true })
        let night = try Self.date(calendar, 2026, 10, 4, 1, 0)
        let next = try #require(schedule.resolve(at: night, location: nil, calendar: calendar).next)
        let wall = calendar.dateComponents([.hour, .minute], from: next)
        #expect(wall.hour == 2 && wall.minute == 30)
    }

    @Test func locationsParseAndComeFromTheTimeZone() throws {
        #expect(BackdropLocation(text: "37.77,-122.42") == BackdropLocation(latitude: 37.77, longitude: -122.42))
        #expect(BackdropLocation(text: " -33.87 , 151.21 ") == BackdropLocation(latitude: -33.87, longitude: 151.21))
        for bad in ["", "37.77", "91,0", "0,181", "north,east", "1,2,3"] { #expect(BackdropLocation(text: bad) == nil, "\(bad)") }
        let table = "# comment\nUS\t+340308-1181434\tAmerica/Los_Angeles\tPacific\nAU\t-3133+15905\tAustralia/Lord_Howe\tLord Howe Island\n"
        let zones = BackdropLocation.parseZoneTable(table)
        let angeles = try #require(zones["America/Los_Angeles"])
        #expect(abs(angeles.latitude - 34.0522) < 0.001 && abs(angeles.longitude + 118.2428) < 0.001)
        let howe = try #require(zones["Australia/Lord_Howe"])
        #expect(abs(howe.latitude + 31.55) < 0.001 && abs(howe.longitude - 159.0833) < 0.001)
        // A zone the table does not list stands at its offset's longitude.
        #expect(BackdropLocation.of(try #require(TimeZone(secondsFromGMT: 3_600 * 9))).longitude == 135)
    }

    /// Every N minutes turns on the local clock from midnight; the next turn is the next multiple.
    @Test func rotationEveryNMinutes() throws {
        let calendar = try Self.calendar("Asia/Tokyo")
        let rotation = try #require(BackdropRotation(rawValue: "45"))
        #expect(rotation == .minutes(45))
        #expect(BackdropRotation(minutes: 90) == .minutes(90))
        #expect(BackdropRotation(rawValue: "0") == nil && BackdropRotation(rawValue: "1441") == nil)
        #expect(BackdropRotation(rawValue: "15m") == .quarterHour)
        let start = try Self.date(calendar, 2026, 5, 10, 10, 10)
        #expect(rotation.nextTurn(after: start, calendar: calendar) == (try Self.date(calendar, 2026, 5, 10, 10, 30)))
        let indices = (0..<4).map { rotation.index(count: 4, on: start.addingTimeInterval(Double($0) * 2_700), calendar: calendar) }
        #expect(Set(indices.compactMap { $0 }).count == 4)
    }
}
