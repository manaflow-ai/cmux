@testable import CmuxNextCompat
import Testing

/// This Mac's shown name (machine identity): a computer name macOS made up names the hardware, so
/// Macs that kept it look alike ("cmux's MacBook Pro (3)"); `displayName` then shows the host name.
struct MacNameTests {
    @Test(arguments: [
        "cmux's MacBook Pro (3)", "Leo’s MacBook Air", "Leos-Mac-mini-2", "iMac", "Leo's Mac", "Mac-Studio",
    ])
    func defaultNamesNameTheHardware(_ name: String) {
        #expect(MacName.isDefaultName(name))
    }

    @Test(arguments: ["cosmic-gray", "air-blue", "Huge Blue", "big-red", "build-mini", "ops-mac", "Primacy", "macproxy"])
    func ownNamesAreKept(_ name: String) {
        #expect(!MacName.isDefaultName(name))
    }
}
