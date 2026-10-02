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

    @Test func onlyABoundAndListeningSocketCounts() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "cu-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }
        #expect(!AppComputerUsePermissionSource.isListening(path))
        // A daemon listening there.
        let listener = try #require(Self.bound(path))
        listen(listener, 1)
        #expect(AppComputerUsePermissionSource.isListening(path))
        // The daemon exits and leaves its socket file behind.
        close(listener)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!AppComputerUsePermissionSource.isListening(path))
    }

    /// A Unix socket bound at `path`, not yet listening.
    static func bound(_ path: String) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }
}
