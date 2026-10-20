@testable import CmuxNextControl
import Testing

@Suite struct ControlServiceAccessModeTests {
    @Test func legacyPasswordModeFailsClosed() {
        #expect(ControlService.parseAccessMode("password") == .off)
        #expect(ControlService.resolveAccessMode(
            explicit: nil,
            environment: ["CMUX_NEXT_SOCKET_MODE": "password"],
            configured: nil
        ) == .off)
        #expect(ControlService.resolveAccessMode(
            explicit: nil,
            environment: [:],
            configured: "password"
        ) == .off)
    }
}
