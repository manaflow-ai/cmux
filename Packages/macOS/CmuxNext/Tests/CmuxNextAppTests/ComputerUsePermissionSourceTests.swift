@testable import CmuxNextApp
import CmuxNextAgentActivity
import CmuxNextOnboarding
import Foundation
import Testing

/// Onboarding's computer use grants come from the cmux-cua daemon's
/// `permissions_status` result, and Allow opens the matching Privacy &
/// Security list.
@MainActor
@Suite struct ComputerUsePermissionSourceTests {
    @Test func grantsAreReadFromThePermissionsStatusResult() {
        let status: [String: Any] = ["accessibility": true, "screen_recording": false, "all_granted": false,
                                     "source": ["pid": 1, "attribution": "driver-daemon"]]
        #expect(AppComputerUsePermissionSource.permissions(status) == ComputerUsePermissions(accessibility: true, screenRecording: false))
        #expect(AppComputerUsePermissionSource.permissions([:]) == .none)
    }

    @Test func allowOpensEachPrivacyList() {
        #expect(AppComputerUsePermissionSource.settingsURL(.accessibility)?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(AppComputerUsePermissionSource.settingsURL(.screenRecording)?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test func aMissingDaemonLeavesTheRowsAsTheyWere() async {
        let path = FileManager.default.temporaryDirectory.appending(path: "cu-\(UUID().uuidString).sock").path
        let source = AppComputerUsePermissionSource(configuration: .init(socketPath: path, machineName: ""))
        let stream = source.permissions()
        let first = Task { await stream.first { _ in true } }
        try? await Task.sleep(for: .milliseconds(300))
        first.cancel()
        #expect(await first.value == nil)
    }
}
