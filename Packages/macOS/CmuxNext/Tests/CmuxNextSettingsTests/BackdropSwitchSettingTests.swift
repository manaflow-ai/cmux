import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The auto-switching background settings: Light and Dark (`appearance`), Time of Day
/// (`schedule`), the dynamic wallpaper mode, the sun location and N-minute rotation.
@Suite struct BackdropSwitchSettingTests {
    static func parse(_ root: JSONValue) -> (BackdropSelection?, [SettingsDiagnostic]) {
        var diagnostics: [SettingsDiagnostic] = []
        let selection = BackdropSelectionSetting().parse(root, diagnostics: &diagnostics)
        return (selection, diagnostics)
    }

    static func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    @Test func lightAndDarkIsAPairResolvedPerAppearance() {
        let root: JSONValue = ["appearance": ["background": "appearance", "backgroundLight": "munch-scream", "backgroundDark": "desktop"]]
        let (selection, diagnostics) = Self.parse(root)
        #expect(diagnostics.isEmpty)
        #expect(selection == .pair(light: .art(.munchScream), dark: .desktop))
        #expect(selection?.resolved(dark: false) == .art(.munchScream))
        #expect(selection?.resolved(dark: true) == .desktop)
        // Light and Dark is no timer: each view resolves it.
        #expect(BackdropSwitch(root) == nil)
        // One side unset shows the other's picture; neither set is none.
        let oneSide: JSONValue = ["appearance": ["background": "appearance", "backgroundDark": "desktop"]]
        #expect(Self.parse(oneSide).0 == .desktop)
        #expect(Self.parse(["appearance": ["background": "appearance"]]).0 == nil)
    }

    @Test func timeOfDayShowsTheScheduledPicture() throws {
        let root: JSONValue = ["appearance": [
            "background": "schedule",
            "backgroundSchedule": .object(["07:00": "munch-scream", "19:00": "desktop"]),
        ]]
        let auto = try #require(BackdropSwitch(root))
        let calendar = try Self.calendar("Asia/Tokyo")
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 9)))
        let turn = auto.turn(at: morning, calendar: calendar)
        #expect(turn.picture == .art(.munchScream))
        #expect(turn.next == calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 19)))
        let night = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 3)))
        #expect(auto.turn(at: night, calendar: calendar).picture == .desktop)
        #expect(Self.parse(root).1.isEmpty)
        // An invalid schedule is a diagnostic and no picture.
        let bad: JSONValue = ["appearance": ["background": "schedule", "backgroundSchedule": .object(["25:00": "desktop"])]]
        let (selection, diagnostics) = Self.parse(bad)
        #expect(selection == nil)
        #expect(diagnostics.map(\.path) == ["appearance.backgroundSchedule"])
    }

    /// N-minute rotation: a number in `appearance.backgroundRotation` turns the shuffle every N
    /// minutes; the switch's next change is the next multiple on the local clock.
    @Test func shuffleTurnsEveryNMinutes() throws {
        let root: JSONValue = ["appearance": ["background": "daily", "backgroundRotation": 20]]
        let auto = try #require(BackdropSwitch(root))
        guard case .shuffle(let shuffle) = auto.source else { Issue.record("not a shuffle"); return }
        #expect(shuffle.rotation == .minutes(20))
        let calendar = try Self.calendar("America/Los_Angeles")
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 9, minute: 5)))
        let turn = auto.turn(at: start, calendar: calendar)
        #expect(turn.next == calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 9, minute: 20)))
        let after = auto.turn(at: try #require(turn.next), calendar: calendar)
        #expect(after.picture != turn.picture)
    }

    /// A dynamic macOS wallpaper only switches with time when `appearance.backgroundDynamic` says so.
    @Test func dynamicTimeIsASwitch() {
        let path = "/System/Library/Desktop Pictures/Sonoma.heic"
        #expect(BackdropSwitch(["appearance": ["background": .string("system:" + path)]]) == nil)
        let auto = BackdropSwitch(["appearance": ["background": .string("system:" + path), "backgroundDynamic": "time",
                                                  "backgroundLocation": "37.77,-122.42"]])
        #expect(auto?.source == .dynamic(path))
        #expect(auto?.location == BackdropLocation(latitude: 37.77, longitude: -122.42))
    }

    @Test func descriptorsAcceptTheNewValues() throws {
        let background = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting.configPath))
        #expect(background.accepts("appearance") && background.accepts("schedule"))
        let light = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting.lightPath))
        #expect(light.accepts("desktop") && light.accepts("file:/Users/Shared/a.png"))
        #expect(!light.accepts("daily") && !light.accepts("folder:/Users/Shared") && !light.accepts("none"))
        let schedule = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting.schedulePath))
        #expect(schedule.accepts(.object(["sunset-30m": "desktop", "07:00": "munch-scream"])))
        #expect(!schedule.accepts(.object(["07:00": "daily"])) && !schedule.accepts(.object(["noonish": "desktop"])))
        let location = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting.locationPath))
        #expect(location.accepts("37.77,-122.42") && !location.accepts("somewhere"))
        let rotation = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting.rotationPath))
        #expect(rotation.accepts(45) && rotation.accepts("hourly") && !rotation.accepts(0) && !rotation.accepts(2_000))
        let dynamic = try #require(SettingsSchema.descriptor(for: BackdropSelectionSetting.dynamicPath))
        #expect(dynamic.accepts("time") && dynamic.accepts("appearance") && !dynamic.accepts("sun"))
        for path in [BackdropSelectionSetting.lightPath, BackdropSelectionSetting.darkPath, BackdropSelectionSetting.schedulePath,
                     BackdropSelectionSetting.dynamicPath, BackdropSelectionSetting.locationPath] {
            #expect(SettingsSchema.agentSettableKeys.contains(path.joined(separator: ".")))
        }
    }
}
