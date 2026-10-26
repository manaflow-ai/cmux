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

/// The host name in this Mac's identity is the local host name its owner set (Sharing), not the
/// kernel's, which DHCP or reverse DNS renames ("dhcp-10-0-1-5"); the kernel's is the fallback.
struct MacNameHostTests {
    @Test func localHostNameBeatsTheKernelName() {
        #expect(MacName.hostName(localHost: "cosmic-gray", kernel: "dhcp-10-0-1-5") == "cosmic-gray")
        #expect(MacName.displayName(computer: "Leo's MacBook Pro (3)", localHost: "cosmic-gray", kernel: "dhcp-10-0-1-5")
            == "cosmic-gray")
    }

    @Test(arguments: [nil, "", "  "] as [String?])
    func kernelNameWhenNoLocalHostName(_ localHost: String?) {
        #expect(MacName.hostName(localHost: localHost, kernel: "cosmic-gray") == "cosmic-gray")
    }

    /// The synchronous `hostName()` (tab badges, terminal moves on the main actor) answers from the
    /// read made off the main actor, never its own configd call.
    @Test func syncHostNameAnswersFromTheOffMainRead() async {
        let local = await MacName.localHostName()
        #expect(MacName().hostName() == MacName.hostName(localHost: local, kernel: MacName().kernelHostName()))
    }
}
