import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextMobile

/// Incognito workspaces never reach a phone (leo-workspace design/spaces.md "Incognito": normal and incognito
/// content never mix; spaces-incognito-audit leak 3). The shipped-iOS compat RPC leaves them out of
/// `mobile.workspace.list`, and every request that names one (by workspace or by terminal) is answered as if it
/// did not exist: no replay, input, rename or close.
struct IncognitoPhoneTests {
    private static let host = MobileCompatHostInfo(macDeviceID: "m", instanceTag: "t", bundleIdentifier: "com.cmuxterm.app.next",
                                                   displayName: "Mac", appVersion: "0", appBuild: "0", daemonLaneAvailable: true)
    private static let normal: WorkspaceKey = "aaaaaaaa-0000-4000-8000-000000000001"
    private static let incognito: WorkspaceKey = "bbbbbbbb-0000-4000-8000-000000000002"
    private static let normalTerminal: TerminalID = "11111111111111111111111111111111"
    private static let incognitoTerminal: TerminalID = "22222222222222222222222222222222"

    /// One normal and one incognito workspace, each with one terminal tab.
    private static func tree() -> DaemonTree {
        let normalTab = TabSnapshot(surface: 1, terminalID: normalTerminal, title: "api shell", cwd: "/work/api")
        let secretTab = TabSnapshot(surface: 2, terminalID: incognitoTerminal, title: "secret shell", cwd: "/private/secret")
        let normalScreen = ScreenSnapshot(id: 1, active: true, activePane: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [normalTab])])
        let secretScreen = ScreenSnapshot(id: 2, active: true, activePane: 2, layout: .leaf(2), panes: [PaneSnapshot(id: 2, tabs: [secretTab])])
        return DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: normal, name: "api-server", screens: [normalScreen]),
            WorkspaceSnapshot(id: 2, key: incognito, name: "secret-project", screens: [secretScreen]),
        ])
    }

    private static func session(hiding hidden: Set<String>) -> (MobileCompatSession, FakeCompatBackend) {
        let gate = PhoneAccessGate()
        gate.setHiddenWorkspaces(hidden)
        let backend = FakeCompatBackend(tree: tree())
        return (MobileCompatSession(backend: backend, host: host, emit: { _ in }, access: gate), backend)
    }

    private static func response(_ session: MobileCompatSession, _ method: String,
                                 _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let frame = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        let raw = await session.handle(frame: frame)
        return try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    private static func errorCode(_ answer: [String: Any]) -> String? {
        (answer["error"] as? [String: Any])?["code"] as? String
    }

    @Test func theListLeavesOutIncognitoWorkspaces() async throws {
        let (session, _) = Self.session(hiding: [Self.incognito.rawValue])
        let answer = try await Self.response(session, "mobile.workspace.list")
        let result = try #require(answer["result"] as? [String: Any], "\(answer)")
        let rows = try #require(result["workspaces"] as? [[String: Any]])
        #expect(rows.map { $0["title"] as? String } == ["api-server"], "the incognito workspace's title reached the phone")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        #expect(!text.contains("secret"), "the incognito workspace's folder or terminal title reached the phone")
    }

    /// A group whose only workspaces are incognito is left out with them (its name could say what they hold); a
    /// group with a normal workspace, and an empty saved group, stay.
    @Test func theListLeavesOutGroupsOfOnlyIncognitoWorkspaces() {
        let tree = DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: Self.normal, name: "api-server", group: "g-work"),
            WorkspaceSnapshot(id: 2, key: Self.incognito, name: "secret-project", group: "g-private"),
        ], groups: [WorkspaceGroupSnapshot(id: "g-work", name: "Work"), WorkspaceGroupSnapshot(id: "g-private", name: "private-secret", index: 1),
                    WorkspaceGroupSnapshot(id: "g-saved", name: "Saved", index: 2, pinned: true)])
        let result = MobileWorkspaceRows.result(for: tree, selected: nil, hides: { $0 == Self.incognito })
        let text = String(describing: result)
        #expect(!text.contains("secret"), "an incognito workspace's group name reached the phone: \(text)")
        #expect(text.contains("Work") && text.contains("Saved"))
    }

    /// The workspace key is matched however the phone or the app spells it.
    @Test func hidingIgnoresCase() {
        let gate = PhoneAccessGate()
        gate.setHiddenWorkspaces([Self.incognito.rawValue.uppercased()])
        #expect(gate.hidesWorkspace(Self.incognito.rawValue))
        #expect(!gate.hidesWorkspace(Self.normal.rawValue))
    }

    @Test(arguments: ["terminal.replay", "mobile.terminal.input", "terminal.paste", "terminal.rename", "terminal.close",
                      "terminal.viewport"])
    func aPhoneCannotReachAnIncognitoTerminal(method: String) async throws {
        let (session, backend) = Self.session(hiding: [Self.incognito.rawValue])
        let surface = try #require(MobileCompatIDs.surfaceID(Self.incognitoTerminal))
        let answer = try await Self.response(session, method, ["surface_id": surface, "text": "ls\r", "title": "x",
                                                               "viewport_columns": 80, "viewport_rows": 24])
        #expect(answer["ok"] as? Bool == false, "\(method) reached an incognito terminal")
        #expect(Self.errorCode(answer) == "not_found")
        #expect(backend.sent.isEmpty)
        #expect(backend.attachSizes.isEmpty)
    }

    @Test(arguments: ["workspace.close", "workspace.action", "terminal.create"])
    func aPhoneCannotActOnAnIncognitoWorkspace(method: String) async throws {
        let (session, _) = Self.session(hiding: [Self.incognito.rawValue])
        let id = Self.incognito.rawValue.uppercased()
        let answer = try await Self.response(session, method, ["workspace_id": id, "action": "rename", "title": "x"])
        #expect(answer["ok"] as? Bool == false, "\(method) acted on an incognito workspace")
        #expect(Self.errorCode(answer) == "not_found")
    }

    /// Normal workspaces work as before beside an incognito one.
    @Test func aNormalTerminalStillWorks() async throws {
        let (session, backend) = Self.session(hiding: [Self.incognito.rawValue])
        let surface = try #require(MobileCompatIDs.surfaceID(Self.normalTerminal))
        let answer = try await Self.response(session, "terminal.input", ["surface_id": surface, "text": "ls\r"])
        #expect(answer["ok"] as? Bool == true, "\(answer)")
        #expect(backend.sent.count == 1)
        let rename = try await Self.response(session, "workspace.action", ["workspace_id": Self.normal.rawValue.uppercased(),
                                                                           "action": "rename", "title": "api"])
        #expect(rename["ok"] as? Bool == true, "\(rename)")
    }
}
