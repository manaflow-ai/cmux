import Foundation
import Testing
@testable import CmuxNextMobile

/// The daemon lane's phone policy: off, a phone can still use what runs on
/// this Mac but cannot create workspaces or terminals; a phone never chooses
/// what runs, and opens only web pages.
struct DaemonLanePolicyStartsSessionsTests {
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
