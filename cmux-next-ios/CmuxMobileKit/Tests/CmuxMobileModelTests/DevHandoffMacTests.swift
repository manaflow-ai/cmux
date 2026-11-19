import Foundation
import Testing
@testable import CmuxMobileModel

/// Aziz's 2026-11-18 report: `review.sh --tag ios-infinite-scroll-v3` launched the tag's phone app with
/// the v3 Mac's pairing code, and the phone linked the `cu-all` dev build on the same Mac instead. Every
/// build on one computer shares its machine id, so the roster listed one of them: of several online
/// builds the lowest device id (`0ae8a0d4…`, cu-all), never the code's (`e7673bc3…`, v3).
@Suite struct DevHandoffMacTests {
    let machine = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
    let cuAll = "0ae8a0d4-d8d9-4872-b541-a48f3dc6cc50"
    let v3 = "e7673bc3-6fc4-4184-ba29-d80ad6743844"

    func mac(_ id: String, online: Bool = true, machine: String? = nil) -> MacDevice {
        MacDevice(id: id, name: "Aziz’s MacBook Pro", isOnline: online, ownerUserID: "me", machineID: machine ?? self.machine)
    }

    func handoff() -> (DevHandoffMac, String) {
        let suite = "cmux.test.dev-handoff.\(UUID().uuidString)"
        return (DevHandoffMac(enabled: true, suiteName: suite), suite)
    }

    /// The code's build is listed for its computer, though another tag's build there is online with a lower id.
    @Test func theCodesBuildIsListedForItsComputer() {
        let macs = [mac(cuAll), mac(v3)]
        #expect(MacRoster(macs, preferring: nil).visible.map(\.id) == [cuAll])
        let roster = MacRoster(macs, preferring: v3)
        #expect(roster.visible.map(\.id) == [v3])
        #expect(roster.hiddenIDs == [cuAll])
    }

    /// Offline, it is still the one listed: the phone waits for its own tag's Mac, never moving to another build.
    @Test func anOfflineCodeBuildStaysListed() {
        #expect(MacRoster([mac(cuAll), mac(v3, online: false)], preferring: v3).visible.map(\.id) == [v3])
    }

    /// Other computers are listed as before; a preferred id on no listed computer changes nothing.
    @Test func otherComputersAreUnchanged() {
        let mini = mac("mini", machine: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2")
        #expect(MacRoster([mac(cuAll), mac(v3), mini], preferring: v3).visible.map(\.id) == [v3, "mini"])
        #expect(MacRoster([mac(cuAll), mac(v3), mini], preferring: "gone").visible.map(\.id) == [cuAll, "mini"])
    }

    /// Remembered across launches: a credential-free relaunch has no code, and keeps the same Mac.
    @Test func theCodesMacIsRememberedAcrossLaunches() throws {
        let (first, suite) = handoff()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        #expect(first.macID == nil)
        first.remember(v3)
        #expect(first.macID == v3)
        #expect(DevHandoffMac(enabled: true, suiteName: suite).macID == v3)
    }

    /// Release, Production, TestFlight and the App Store prefer no build: the roster lists as it always did.
    @Test func onlyTaggedDevBuildsPreferABuild() {
        let suite = "cmux.test.dev-handoff.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let off = DevHandoffMac(enabled: false, suiteName: suite)
        off.remember(v3)
        #expect(off.macID == nil)
        #expect(UserDefaults(suiteName: suite)?.string(forKey: DevHandoffMac.key) == nil)
        #expect(DevHandoffMac.isTaggedDevBuild("dev.cmux.mobile.ios-infinite-scroll-v3"))
        for id in ["com.cmux.app", "dev.cmux.app.internal", "dev.cmux.app.beta", "dev.cmux.mobile", "dev.cmux.mobile.", nil] {
            #expect(!DevHandoffMac.isTaggedDevBuild(id))
        }
        #expect(DevHandoffMac(bundleID: "com.cmux.app").macID == nil)
    }
}
