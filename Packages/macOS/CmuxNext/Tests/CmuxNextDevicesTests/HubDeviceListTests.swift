@testable import CmuxNextDevices
import Foundation
import Testing

/// Leo's Screen Sharing page listed the Mac he sat on twice, both Offline, while he sat on it
/// (2026-11-15): each cmux build (NIGHTLY, DEV) is its own hub identity with the same Computer Name. The
/// list is one row per physical device, and this Mac's other builds are This Mac (Rust `device_list`).
@Suite struct HubDeviceListTests {
    @Test func thisMacsOtherBuildsAreNotRemotesAndDuplicatesListOnce() {
        let devices = [
            HubDevice(id: "dev", name: "Desk Mac", platform: .macos),
            HubDevice(id: "nightly", name: "Desk Mac", platform: .macos, online: true),
            HubDevice(id: "air-old", name: "Laptop", platform: .macos, lastSeenAt: Date(timeIntervalSince1970: 10)),
            HubDevice(id: "air", name: "Laptop", platform: .macos, macScreenShared: true, online: true),
            HubDevice(id: "phone", name: "Leo’s iPhone", platform: .ios),
        ]
        let list = HubDeviceList.make(thisID: "nightly", devices: devices)
        #expect(list.thisDevice == ["nightly", "dev"])
        #expect(list.others.map(\.id) == ["air", "phone"])
    }

    /// Before the hub lists this Mac's own record, its registered name still marks its other builds.
    @Test func thisMacsNameMarksItBeforeItsRecordIsListed() {
        let devices = [HubDevice(id: "dev", name: "Desk Mac", platform: .macos), HubDevice(id: "air", name: "Laptop", platform: .macos)]
        let list = HubDeviceList.make(thisID: "nightly", thisName: "Desk Mac", thisPlatform: .macos, devices: devices)
        #expect(list.others.map(\.id) == ["air"])
    }

    /// Typographic quotes, case and punctuation fold; a phone and a Mac of one name stay two devices.
    @Test func namesFoldButPlatformsDoNot() {
        let devices = [
            HubDevice(id: "m1", name: "Leo’s Mac", platform: .macos),
            HubDevice(id: "m2", name: "leos-mac", platform: .macos, online: true),
            HubDevice(id: "p1", name: "Leo's Mac", platform: .ios),
        ]
        #expect(HubDeviceList.make(thisID: "me", devices: devices).others.map(\.id) == ["m2", "p1"])
    }
}
