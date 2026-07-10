import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator permission presentation")
struct SimulatorNotificationPrivacyToolsTests {
    @Test("All is reset-only and targeted mutations require an app")
    func actionAvailability() {
        #expect(!SimulatorNotificationPrivacyTools.actionIsEnabled(
            .grant, service: .all, bundleIdentifier: "com.example.app"
        ))
        #expect(!SimulatorNotificationPrivacyTools.actionIsEnabled(
            .revoke, service: .camera, bundleIdentifier: "  "
        ))
        #expect(SimulatorNotificationPrivacyTools.actionIsEnabled(
            .grant, service: .camera, bundleIdentifier: "com.example.app"
        ))
        #expect(!SimulatorNotificationPrivacyTools.actionIsEnabled(
            .reset, service: .all, bundleIdentifier: ""
        ))
        #expect(SimulatorNotificationPrivacyTools.actionIsEnabled(
            .reset, service: .all, bundleIdentifier: "com.example.app"
        ))
    }

    @Test("Foreground app fills only an empty permission target")
    func foregroundBundleDefault() {
        #expect(SimulatorNotificationPrivacyTools.bundleIdentifier(
            current: "",
            foreground: "com.example.foreground"
        ) == "com.example.foreground")
        #expect(SimulatorNotificationPrivacyTools.bundleIdentifier(
            current: "com.example.override",
            foreground: "com.example.foreground"
        ) == "com.example.override")
        #expect(SimulatorNotificationPrivacyTools.bundleIdentifier(
            current: "  ",
            foreground: nil
        ) == "  ")
    }
}
