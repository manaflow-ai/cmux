@testable import CmuxNextControl
import Foundation
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

    @Test func legacyCrossUserModesNarrowToSameUserAutomation() {
        for mode in ["allowAll", "openAccess", "fullOpenAccess", "full"] {
            #expect(ControlService.parseAccessMode(mode) == .automation)
        }
    }

    /// The in-place update from classic cmux: a person who chose a stricter socket
    /// mode in classic's Settings keeps it; cmux.json and the environment still win.
    @Test func classicsStoredChoiceOutranksTheNewDefault() throws {
        let name = "cn-classic-socket-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        #expect(ControlService.classicStoredMode(defaults) == nil)
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: [:], configured: nil,
                                                 classic: ControlService.classicStoredMode(defaults)) == .automation)

        defaults.set("cmuxOnly", forKey: "socketControlMode")
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: [:], configured: nil,
                                                 classic: ControlService.classicStoredMode(defaults)) == .cmuxOnly)
        defaults.set("off", forKey: "socketControlMode")
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: [:], configured: nil,
                                                 classic: ControlService.classicStoredMode(defaults)) == .off)
        defaults.set("password", forKey: "socketControlMode")
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: [:], configured: nil,
                                                 classic: ControlService.classicStoredMode(defaults)) == .off)
        // cmux.json and the environment still decide first.
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: [:], configured: "automation",
                                                 classic: "off") == .automation)
        #expect(ControlService.resolveAccessMode(explicit: nil, environment: ["CMUX_NEXT_SOCKET_MODE": "cmuxOnly"],
                                                 configured: nil, classic: "off") == .cmuxOnly)
        // Classic's older on/off switch.
        defaults.removeObject(forKey: "socketControlMode")
        defaults.set(false, forKey: "socketControlEnabled")
        #expect(ControlService.classicStoredMode(defaults) == "off")
    }
}
