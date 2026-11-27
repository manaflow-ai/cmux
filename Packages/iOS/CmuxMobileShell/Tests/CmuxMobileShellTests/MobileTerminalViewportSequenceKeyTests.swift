import Testing
@testable import CmuxMobileShell

@Suite("Terminal viewport preparation ownership")
struct MobileTerminalViewportSequenceKeyTests {
    @Test("preparations for two Mac app instances do not collide")
    func appInstanceOwnsPreparationMarker() {
        let surfaceID = "terminal"
        let first = MobileTerminalViewportSequenceKey(
            ownerKey: MacPairingKey(macDeviceID: "mac", instanceTag: "first"),
            surfaceID: surfaceID
        )
        let second = MobileTerminalViewportSequenceKey(
            ownerKey: MacPairingKey(macDeviceID: "mac", instanceTag: "second"),
            surfaceID: surfaceID
        )
        var markers: [MobileTerminalViewportSequenceKey: UInt64] = [first: 1]

        #expect(first != second)
        #expect(markers[second] == nil)
        markers[second] = 1
        #expect(markers.count == 2)
    }
}
