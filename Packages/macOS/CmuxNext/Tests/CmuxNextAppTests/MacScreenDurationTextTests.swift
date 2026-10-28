@testable import CmuxNextMacScreen
import Testing

/// History's duration column: an audit entry's `durationS` comes from the device hub.
/// Before, `durationText` converted it with `Int(_:)` and a duration of 1e300 or NaN stopped the app; now a
/// value that is not whole seconds in range shows no duration, as an entry without one does.
@MainActor
struct MacScreenDurationTextTests {
    @Test func aDurationNoEntryHasShowsNone() {
        #expect(MacScreenDevicesSettings.durationText(1e300) == "")
        #expect(MacScreenDevicesSettings.durationText(.infinity) == "")
        #expect(MacScreenDevicesSettings.durationText(.nan) == "")
        #expect(MacScreenDevicesSettings.durationText(-1) == "")
    }

    @Test func wholeSecondsReadAsBefore() {
        #expect(MacScreenDevicesSettings.durationText(0) == "0s")
        #expect(MacScreenDevicesSettings.durationText(8.4) == "8s")
        #expect(MacScreenDevicesSettings.durationText(1347) == "22m 27s")
        #expect(MacScreenDevicesSettings.durationText(3840) == "1h 4m")
    }
}
