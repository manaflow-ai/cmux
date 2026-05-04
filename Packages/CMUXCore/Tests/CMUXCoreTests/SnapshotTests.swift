import CMUXCore
import XCTest

final class SnapshotTests: XCTestCase {
    func testWorkspaceSnapshotRoundTripsStableWireKeys() throws {
        let snapshot = WorkspaceSnapshot(
            id: "workspace-1",
            name: "Linux Port",
            rootPath: "/home/user/project",
            activeSessionID: "session-1",
            sessionIDs: ["session-1", "session-2"]
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)

        XCTAssertEqual(object?["root_path"] as? String, "/home/user/project")
        XCTAssertEqual(object?["active_session_id"] as? String, "session-1")
        XCTAssertEqual(object?["session_ids"] as? [String], ["session-1", "session-2"])
        XCTAssertEqual(decoded, snapshot)
    }

    func testSessionSnapshotRoundTripsStableWireKeys() throws {
        let snapshot = SessionSnapshot(
            id: "session-1",
            workspaceID: "workspace-1",
            title: "Build",
            currentDirectory: "/home/user/project",
            isActive: true
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(object?["workspace_id"] as? String, "workspace-1")
        XCTAssertEqual(object?["current_directory"] as? String, "/home/user/project")
        XCTAssertEqual(object?["is_active"] as? Bool, true)
        XCTAssertEqual(decoded, snapshot)
    }
}
