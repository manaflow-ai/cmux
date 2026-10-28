import Foundation
import Testing
@testable import CmuxNextPhone

@Suite struct PhoneDeviceListTests {
    @Test func simulatorsAreIOSOnlyBootedFirstNewestRuntimeFirst() throws {
        let phones = try SimctlDeviceList().parse(fixture("simctl-list"))
        #expect(phones.map(\.name) == ["iPhone 18 Pro", "iPhone 17e", "iPad Pro 11-inch (M4)", "iPhone 16", "iPhone SE (3rd generation)"])
        #expect(phones[0].state == .ready)
        #expect(phones[0].osVersion == "iOS 27.0")
        #expect(phones[0].id.description == "sim:6A05764C-FFD1-4B40-AA2E-AD27ADAC7A56")
        #expect(phones.first { $0.name == "iPhone 16" }?.state == .booting)
        #expect(phones.first { $0.name.hasPrefix("iPhone SE") }?.state == .unavailable(reason: "runtime profile not found"))
        #expect(!phones.contains { $0.name.contains("Watch") })
    }

    @Test func simulatorModelComesFromTheDeviceTypeNotTheName() {
        #expect(SimctlDeviceList.model(typeID: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max", fallback: "x") == "iPhone 18 Pro Max")
        #expect(SimctlDeviceList.model(typeID: "com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K", fallback: "my tv") == "my tv")
        #expect(SimctlDeviceList.model(typeID: nil, fallback: "renamed") == "renamed")
    }

    @Test func realDevicesArePhysicalIOSOnlyWithTransport() throws {
        let phones = try DevicectlDeviceList().parse(fixture("devicectl-list"))
        #expect(phones.map(\.name) == ["Test’s iPhone", "Lab iPhone"])
        #expect(phones[0].id == PhoneDeviceID(mode: .device, raw: "00008140-0000000000000001"))
        #expect(phones[0].model == "iPhone 16 Pro")
        #expect(phones[0].transport == "usb")
        #expect(phones[1].transport == "wifi")
        #expect(phones.allSatisfy { $0.state == .ready })
    }

    @Test(arguments: ["sim:ABC", "dev:0000-1", "vm:my phone"])
    func idsRoundTripThroughTheirStringForm(_ text: String) throws {
        let id = try #require(PhoneDeviceID(text))
        #expect(id.description == text)
        let data = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(PhoneDeviceID.self, from: data) == id)
    }

    @Test(arguments: ["", "sim:", "ABC", "usb:123"])
    func badIdsAreRejected(_ text: String) {
        #expect(PhoneDeviceID(text) == nil)
    }
}
