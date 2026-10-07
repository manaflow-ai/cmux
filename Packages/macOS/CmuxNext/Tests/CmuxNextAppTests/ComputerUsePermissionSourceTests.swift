@testable import CmuxNextApp
import CmuxNextAgentActivity
import CmuxNextControl
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
        let first = Task { () -> ComputerUsePermissions? in
            for await value in stream { return value }
            return nil
        }
        try? await Task.sleep(for: .milliseconds(300))
        first.cancel()
        #expect(await first.value == nil)
    }

    /// A daemon that answers, but refuses `permissions_status` or answers
    /// without the two grants, speaks another protocol version: the step
    /// gets a visible mismatch, not silence.
    @Test(arguments: [#"{"ok":false,"error":"unknown method: permissions_status"}"#,
                      #"{"ok":true,"result":{"granted":true}}"#])
    func aHelperOnAnotherProtocolIsAVersionMismatch(_ reply: String) async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "cu-\(UUID().uuidString.prefix(8)).sock").path
        defer { unlink(path) }
        let listener = try #require(Self.bound(path))
        defer { close(listener) }
        listen(listener, 4)
        Self.answerEachRequest(on: listener, with: reply)
        let source = AppComputerUsePermissionSource(configuration: .init(socketPath: path, machineName: ""))
        let stream = source.permissions()
        let first = Task { () -> ComputerUsePermissions? in
            for await value in stream { return value }
            return nil
        }
        let deadline = Task { try? await Task.sleep(for: .seconds(5)); first.cancel() }
        let value = await first.value
        deadline.cancel()
        #expect(value?.helperVersionMismatch == true)
    }

    /// Accepts connections on `listener` and answers each request line with
    /// `reply`, until the listener closes.
    static func answerEachRequest(on listener: Int32, with reply: String) {
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                // A connection that sends no request (the client's server-uid
                // check) gets no reply.
                var byte: UInt8 = 0
                var gotLine = false
                while read(client, &byte, 1) == 1 { if byte == UInt8(ascii: "\n") { gotLine = true; break } }
                if gotLine {
                    let line = Array((reply + "\n").utf8)
                    _ = line.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                }
                close(client)
            }
        }
    }

    /// The app strips every inherited CMUX* variable except CMUX_NEXT_* at
    /// launch (LaunchIdentity), so the socket override and its tokens use
    /// CMUX_NEXT_ names: a tagged app and its tests then reach their own
    /// cmux-cua socket and never the shared default path.
    @Test func theSocketOverrideSurvivesTheLaunchStrip() {
        let launched = ["CMUX_NEXT_CUA_SOCKET": "/tmp/tag-scoped/cmux-cua.sock",
                        "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": "agent-token",
                        "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN": "host-token",
                        "CMUX_CUA_SOCKET": "/tmp/inherited-from-a-parent.sock"]
        let stripped = Set(LaunchIdentity.inheritedKeys(processEnvironment: launched, bundledEnvironment: [:]))
        let environment = launched.filter { !stripped.contains($0.key) }
        let configuration = AgentActivitySocketSource.Configuration.standard(machineName: "", environment: environment,
                                                                            home: "/Users/someone")
        #expect(configuration.socketPath == "/tmp/tag-scoped/cmux-cua.sock")
        #expect(configuration.authToken == "agent-token")
        #expect(configuration.hostAuthToken == "host-token")
    }

    /// Without the override the app reads cmux-cua's default socket, and an
    /// old CMUX_CUA_SOCKET (a parent's, or the helper's own) is never used.
    @Test func withoutTheOverrideTheDefaultSocketIsUsed() {
        let configuration = AgentActivitySocketSource.Configuration.standard(
            machineName: "", environment: ["CMUX_CUA_SOCKET": "/tmp/inherited-from-a-parent.sock",
                                           "CMUX_CUA_SOCKET_AUTH_TOKEN": "inherited"],
            home: "/Users/someone")
        #expect(configuration.socketPath == "/Users/someone/Library/Caches/cmux-cua/cmux-cua.sock")
        #expect(configuration.authToken == nil)
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
