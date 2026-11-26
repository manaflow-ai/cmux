@testable import CmuxNextDevices
import Foundation
import Testing

/// Leo, 2026-11-16, on Settings > Screen Sharing ("this needs to shut up"): the Mac he sat on listed twice
/// and two other Macs twice each, because every cmux build and every identity renewal is its own hub record.
/// `DeviceList` asks Rust (`cloud_identity_device_list`) which records are one Mac; `otherDevices` lists each once.
@Suite struct DeviceListTests {
    static let now = Date(timeIntervalSince1970: 1_794_800_000)

    static func mac(_ id: String, _ name: String, online: Bool = false, shared: Bool = true, seen: TimeInterval = 0) -> HubDevice {
        HubDevice(id: id, name: name, platform: .macos, lastSeenAt: now.addingTimeInterval(seen), macScreenShared: shared, online: online)
    }

    @Test func oneEntryPerMacAndThisMacsOtherBuildsAreNotRemotes() {
        let devices = [
            Self.mac("this-nightly", "Studio", online: true),
            Self.mac("this-dev", "Studio"),
            Self.mac("air-old", "Air", seen: -9000),
            Self.mac("air-new", "Air", online: true),
            Self.mac("mini-a", "Office mini", seen: -100),
            Self.mac("mini-b", "Office mini", seen: -10),
            Self.mac("den", "Den", online: true, shared: false),
        ]
        let list = DeviceList.make(thisID: "this-nightly", thisName: "Studio", platform: .macos, devices: devices)
        #expect(list.thisDevice == ["this-nightly", "this-dev"])
        #expect(list.others.map(\.id) == ["air-new", "mini-b", "den"])
        #expect(list.others.first { $0.id == "mini-b" }?.ids == ["mini-b", "mini-a"])
    }

    @Test func namesMatchAcrossPunctuationAndCase() {
        let devices = [Self.mac("a", "Leo’s Mac mini (3)"), Self.mac("b", "leo's mac mini (3)", online: true)]
        let list = DeviceList.make(thisID: "me", thisName: "Laptop", platform: .macos, devices: devices)
        #expect(list.others.map(\.id) == ["b"])
        #expect(list.others.first?.ids == ["b", "a"])
    }

    static func mac(_ id: String, _ name: String, machine: String, online: Bool = false) -> HubDevice {
        HubDevice(id: id, name: name, platform: .macos, lastSeenAt: now, macScreenShared: true, online: online, machineId: machine)
    }

    /// Whether the linked app FFI groups by `machineId` (cmux#44770): two machine ids under one name stay
    /// two devices. Until the FFI pin carries that release the name rule decides, and the case below waits.
    static let ffiGroupsByMachineID: Bool = {
        let devices = [mac("a", "Mac mini", machine: "m-a"), mac("b", "Mac mini", machine: "m-b")]
        return DeviceList.make(thisID: "me", thisName: "Laptop", platform: .macos, devices: devices).others.count == 2
    }()

    /// The hub's machine id makes one Mac one row even when its builds' records carry different names
    /// (a DEV renamed in Settings), and marks this Mac's other builds by machine, not by name.
    @Test(.enabled(if: ffiGroupsByMachineID)) func recordsOfOneMachineListOnceWhateverTheirNames() {
        let devices = [
            Self.mac("this-nightly", "Studio", machine: "m-this", online: true),
            Self.mac("this-dev", "Studio (DEV)", machine: "m-this"),
            Self.mac("mini-nightly", "Office mini", machine: "m-mini", online: true),
            Self.mac("mini-dev", "Renamed mini", machine: "m-mini"),
        ]
        let list = DeviceList.make(thisID: "this-nightly", thisName: "Studio", platform: .macos, thisMachineID: "m-this", devices: devices)
        #expect(list.thisDevice == ["this-nightly", "this-dev"])
        #expect(list.others.map(\.id) == ["mini-nightly"])
        #expect(list.others.first?.ids == ["mini-nightly", "mini-dev"])
    }
}
