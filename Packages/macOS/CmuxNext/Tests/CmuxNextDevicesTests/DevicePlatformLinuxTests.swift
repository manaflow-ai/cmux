@testable import CmuxNextDevices
import Foundation
import Testing

/// A Linux desktop that shares its screen (`cmux-rd linux-host`) registers with the hub as `linux`.
@Suite struct DevicePlatformLinuxTests {
    @Test func aLinuxHostDecodesAsLinuxAndSharing() throws {
        let json = #"{"id":"6f1c2a4e-0d3b-4c5a-9e7f-112233445566","name":"Desktop","platform":"linux","macScreenShared":1,"online":true}"#
        let device = try JSONDecoder().decode(HubDevice.self, from: Data(json.utf8))
        #expect(device.platform == .linux)
        #expect(device.macScreenShared)
        #expect(device.online)
    }

    @Test func aPlatformThisAppDoesNotKnowStillDecodes() throws {
        let json = #"{"id":"d1","name":"Box","platform":"freebsd","macScreenShared":true}"#
        let device = try JSONDecoder().decode(HubDevice.self, from: Data(json.utf8))
        #expect(device.platform == nil)
        #expect(device.macScreenShared)
    }

    @Test func aWindowsPCDecodesAsWindows() throws {
        let json = #"{"id":"7a2b3c4d-0d3b-4c5a-9e7f-112233445566","name":"DESKTOP-1","platform":"windows","macScreenShared":0,"online":true}"#
        let device = try JSONDecoder().decode(HubDevice.self, from: Data(json.utf8))
        #expect(device.platform == .windows)
        #expect(!device.macScreenShared)
        #expect(device.online)
    }
}
