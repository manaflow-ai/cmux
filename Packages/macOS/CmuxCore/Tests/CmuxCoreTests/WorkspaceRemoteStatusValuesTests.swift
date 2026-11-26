import CmuxCore
import Foundation
import Testing

@Suite("Remote status values")
struct WorkspaceRemoteStatusValuesTests {
    @Test("connection state raw values are pinned wire strings")
    func connectionStateRawValues() {
        #expect(WorkspaceRemoteConnectionState.disconnected.rawValue == "disconnected")
        #expect(WorkspaceRemoteConnectionState.connecting.rawValue == "connecting")
        #expect(WorkspaceRemoteConnectionState.reconnecting.rawValue == "reconnecting")
        #expect(WorkspaceRemoteConnectionState.connected.rawValue == "connected")
        #expect(WorkspaceRemoteConnectionState.error.rawValue == "error")
        #expect(WorkspaceRemoteConnectionState.suspended.rawValue == "suspended")
    }

    @Test("daemon state raw values are pinned wire strings")
    func daemonStateRawValues() {
        #expect(WorkspaceRemoteDaemonState.unavailable.rawValue == "unavailable")
        #expect(WorkspaceRemoteDaemonState.bootstrapping.rawValue == "bootstrapping")
        #expect(WorkspaceRemoteDaemonState.ready.rawValue == "ready")
        #expect(WorkspaceRemoteDaemonState.error.rawValue == "error")
    }

    @Test("default daemon status matches the legacy zero value")
    func defaultStatus() {
        let status = WorkspaceRemoteDaemonStatus()
        #expect(status.state == .unavailable)
        #expect(status.detail == nil)
        #expect(status.version == nil)
        #expect(status.name == nil)
        #expect(status.capabilities.isEmpty)
        #expect(status.remotePath == nil)
    }

    @Test("payload keeps wire keys and NSNull placeholders")
    func payloadShape() {
        let empty = WorkspaceRemoteDaemonStatus().payload()
        #expect(Set(empty.keys) == ["state", "detail", "version", "name", "capabilities", "remote_path"])
        #expect(empty["state"] as? String == "unavailable")
        #expect(empty["detail"] is NSNull)
        #expect(empty["version"] is NSNull)
        #expect(empty["name"] is NSNull)
        #expect((empty["capabilities"] as? [String]) == [])
        #expect(empty["remote_path"] is NSNull)

        let full = WorkspaceRemoteDaemonStatus(
            state: .ready,
            detail: "ok",
            version: "1.2.3",
            name: "cmuxd-remote",
            capabilities: ["pty.session", "proxy.stream.push"],
            remotePath: "/home/u/.cmux/cmuxd-remote"
        ).payload()
        #expect(full["state"] as? String == "ready")
        #expect(full["detail"] as? String == "ok")
        #expect(full["version"] as? String == "1.2.3")
        #expect(full["name"] as? String == "cmuxd-remote")
        #expect((full["capabilities"] as? [String]) == ["pty.session", "proxy.stream.push"])
        #expect(full["remote_path"] as? String == "/home/u/.cmux/cmuxd-remote")
        #expect(JSONSerialization.isValidJSONObject(full))
    }
}
