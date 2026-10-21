import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextMobile

/// `phone.startSessions` (Settings > Accounts > Phone Access): off, a phone
/// can still use what runs on this Mac but cannot create workspaces or
/// terminals, on the shipped compat RPC and on daemon lanes alike. The gate
/// is read per request, so turning it off applies to connected phones too.
struct PhoneAccessGateTests {
    private static let host = MobileCompatHostInfo(macDeviceID: "m", instanceTag: "t", bundleIdentifier: "com.cmuxterm.app.next",
                                                   displayName: "Mac", appVersion: "0", appBuild: "0", daemonLaneAvailable: true)

    private static func response(_ session: MobileCompatSession, _ method: String,
                                 _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let frame = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        let raw = await session.handle(frame: frame)
        return try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    @Test(arguments: ["workspace.create", "mobile.terminal.create", "terminal.create"])
    func compatRefusesStartingWhileOff(method: String) async throws {
        let gate = PhoneAccessGate(allowsStartingSessions: false)
        let session = MobileCompatSession(backend: FakeCompatBackend(tree: DaemonTree()), host: Self.host,
                                          emit: { _ in }, access: gate)
        let answer = try await Self.response(session, method, ["title": "phone"])
        #expect(answer["ok"] as? Bool == false)
        let error = try #require(answer["error"] as? [String: Any])
        #expect(error["code"] as? String == "forbidden")
    }

    @Test func compatStillListsWhileOff() async throws {
        let session = MobileCompatSession(backend: FakeCompatBackend(tree: DaemonTree()), host: Self.host,
                                          emit: { _ in }, access: PhoneAccessGate(allowsStartingSessions: false))
        #expect(try await Self.response(session, "mobile.workspace.list")["ok"] as? Bool == true)
    }

    @Test func turningItBackOnAppliesToTheOpenSession() async throws {
        let gate = PhoneAccessGate(allowsStartingSessions: false)
        let session = MobileCompatSession(backend: FakeCompatBackend(tree: DaemonTree()), host: Self.host,
                                          emit: { _ in }, access: gate)
        #expect(try await Self.response(session, "workspace.create", ["title": "a"])["ok"] as? Bool == false)
        gate.setAllowsStartingSessions(true)
        let error = try await Self.response(session, "workspace.create", ["title": "a"])["error"] as? [String: Any]
        #expect(error?["code"] as? String != "forbidden")
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test(arguments: ["create-workspace", "new-workspace", "create-terminal", "new-tab", "split", "new-pane",
                      "new-browser-tab", "reopen-saved-tab-group", "move-tab-to-new-workspace",
                      "move-tab-group-to-new-workspace"])
    func daemonLaneRefusesStartingWhileOff(command: String) throws {
        let policy = DaemonLanePolicy(deviceID: "p", allowsStartingSessions: { false })
        guard case .refuse(let data) = policy.evaluate(try Self.line(["id": 1, "cmd": command])) else {
            Issue.record("\(command) was forwarded")
            return
        }
        let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(answer["error_code"] as? String == "forbidden")
    }

    @Test func daemonLaneKeepsEverythingElseWhileOff() throws {
        let policy = DaemonLanePolicy(deviceID: "p", allowsStartingSessions: { false })
        for command in ["list-workspaces", "send", "attach-surface", "close-terminal"] {
            #expect(policy.evaluate(try Self.line(["id": 1, "cmd": command])) == .forward, "\(command)")
        }
    }

    @Test func daemonLaneStartsByDefault() throws {
        #expect(DaemonLanePolicy(deviceID: "p").evaluate(try Self.line(["id": 1, "cmd": "create-workspace"])) == .forward)
    }

    /// A phone never chooses what runs: `respawn` (a fresh shell with cwd, env and shell_args on
    /// `move-tab-to-split` and `move-tab-to-column`) and bare program fields are refused, with
    /// starting new workspaces on or off.
    @Test(arguments: [true, false])
    func daemonLaneRefusesRespawnAndProgramFields(startsSessions: Bool) throws {
        let policy = DaemonLanePolicy(deviceID: "p", allowsStartingSessions: { startsSessions })
        let respawn: [String: Any] = ["kind": "terminal", "cwd": "/tmp", "env": ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"],
                                      "shell_args": ["-c", "id"]]
        for command in ["move-tab-to-split", "move-tab-to-column"] {
            let line = try Self.line(["id": 1, "cmd": command, "surface": "s", "respawn": respawn])
            guard case .refuse(let data) = policy.evaluate(line) else {
                Issue.record("\(command) with respawn was forwarded")
                continue
            }
            let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(answer["error_code"] as? String == "forbidden")
        }
        for field in ["env", "shell_args", "argv", "command"] {
            let line = try Self.line(["id": 1, "cmd": "send", field: ["x"]])
            #expect(policy.evaluate(line) != .forward, "\(field)")
        }
        #expect(policy.evaluate(try Self.line(["id": 1, "cmd": "move-tab-to-split", "surface": "s", "edge": "right"])) == .forward)
    }

    /// Fields are an allowlist per command too (the daemon's schema minus program fields), so a field
    /// the daemon adds later is refused until it is reviewed.
    @Test func aFieldOffTheCommandsListIsRefused() throws {
        let policy = DaemonLanePolicy(deviceID: "p")
        #expect(policy.evaluate(try Self.line(["id": 1, "cmd": "send", "surface": "s", "text": "ls"])) == .forward)
        #expect(policy.evaluate(try Self.line(["id": 1, "cmd": "send", "surface": "s", "future_field": true])) != .forward)
    }

    @Test(arguments: ["file:///etc/passwd", "FILE:///tmp/x", "javascript:alert(1)", "cmux://settings", "not a url"])
    func aPhoneOpensOnlyWebPages(url: String) throws {
        let policy = DaemonLanePolicy(deviceID: "p")
        #expect(policy.evaluate(try Self.line(["id": 1, "cmd": "browser-navigate", "surface": "s", "url": url])) != .forward)
    }

    @Test func aURLThatIsNotAStringIsRefused() throws {
        let policy = DaemonLanePolicy(deviceID: "p")
        for url: Any in [["file:///etc/passwd"], ["href": "file:///etc/passwd"], 7] {
            #expect(policy.evaluate(try Self.line(["id": 1, "cmd": "browser-navigate", "surface": "s", "url": url])) != .forward,
                    "\(url)")
        }
    }

    @Test func webPagesStillOpen() throws {
        let policy = DaemonLanePolicy(deviceID: "p")
        #expect(policy.evaluate(try Self.line(["id": 1, "cmd": "browser-navigate", "surface": "s", "url": "https://example.com"])) == .forward)
    }

    @Test func everyAllowedCommandHasAFieldList() {
        #expect(Set(DaemonLanePolicy.commandFields.keys) == DaemonLanePolicy.allowedCommands)
    }
}
