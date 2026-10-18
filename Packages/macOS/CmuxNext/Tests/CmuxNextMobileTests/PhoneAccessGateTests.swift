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
                      "new-browser-tab", "reopen-saved-tab-group"])
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
}
