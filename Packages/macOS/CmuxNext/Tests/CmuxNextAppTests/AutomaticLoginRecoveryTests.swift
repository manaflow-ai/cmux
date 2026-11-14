import Foundation
import Testing
@testable import CmuxNextApp

/// Login recovery belongs to a person's app session. Capture slots are the only disposable launches that
/// opt out, so a normal agent launch comes back with its persisted chat and terminal state after a reboot.
struct AutomaticLoginRecoveryTests {
    @Test func aNormalNoActivateLaunchKeepsLoginRecoveryEnabled() {
        let environment = AppEnvironment.current(["CMUX_NEXT_NO_ACTIVATE": "1"])

        #expect(environment.noActivate)
        #expect(environment.captureShellHome == nil)
    }

    @Test func aCaptureSlotRemainsOptedOutOfLoginRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-capture-login-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = AppEnvironment.current([
            "CMUX_NEXT_NO_ACTIVATE": "1",
            "CMUX_CAPTURE_SHELL_HOME": root.path,
        ])

        #expect(environment.noActivate)
        #expect(environment.captureShellHome == root.path)
    }
}
