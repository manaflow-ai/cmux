import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator permission presentation")
struct SimulatorNotificationPrivacyToolsTests {
    @Test("All is reset-only and targeted mutations require an app")
    func actionAvailability() {
        #expect(!simulatorPrivacyActionIsEnabled(
            .grant, service: .all, bundleIdentifier: "com.example.app"
        ))
        #expect(!simulatorPrivacyActionIsEnabled(
            .revoke, service: .camera, bundleIdentifier: "  "
        ))
        #expect(simulatorPrivacyActionIsEnabled(
            .grant, service: .camera, bundleIdentifier: "com.example.app"
        ))
        #expect(!simulatorPrivacyActionIsEnabled(
            .reset, service: .all, bundleIdentifier: ""
        ))
        #expect(simulatorPrivacyActionIsEnabled(
            .reset, service: .all, bundleIdentifier: "com.example.app"
        ))
    }

    @Test("Foreground app fills only an empty permission target")
    func foregroundBundleDefault() {
        #expect(simulatorPrivacyBundleIdentifier(
            current: "",
            foreground: "com.example.foreground"
        ) == "com.example.foreground")
        #expect(simulatorPrivacyBundleIdentifier(
            current: "com.example.override",
            foreground: "com.example.foreground"
        ) == "com.example.override")
        #expect(simulatorPrivacyBundleIdentifier(
            current: "  ",
            foreground: nil
        ) == "  ")
    }
}
