import CmuxNextDaemon
@testable import CmuxNextApp
import Testing

/// Personal snapshots normally contain unique contiguous placement indices.
/// These tests cover the short handoff window where two placement rows can
/// temporarily share an index while a rapid create batch is being reconciled.
@MainActor
struct PersonalSidebarOrderTests {
    private static func workspace(_ key: String, id: UInt64) -> WorkspaceModel {
        WorkspaceModel(WorkspaceSnapshot(id: WorkspaceHandle(rawValue: id),
                                          key: WorkspaceKey(rawValue: key),
                                          name: key))
    }

    @Test func duplicatePlacementIndicesUseStableKeys() {
        let first = Self.workspace("key-b", id: 1)
        let second = Self.workspace("key-a", id: 2)
        let rows = [
            PersonalWorkspace(sessionID: "session", workspaceKey: first.key!, index: 7),
            PersonalWorkspace(sessionID: "session", workspaceKey: second.key!, index: 7),
        ]

        let ordered = PersonalSidebar.order([first, second], rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.workspaceKey.rawValue, $0) }))

        #expect(ordered.map { $0.key?.rawValue } == ["key-a", "key-b"])
    }

    @Test func distinctPlacementIndicesRemainAuthoritative() {
        let first = Self.workspace("key-b", id: 1)
        let second = Self.workspace("key-a", id: 2)
        let rows = [
            PersonalWorkspace(sessionID: "session", workspaceKey: first.key!, index: 2),
            PersonalWorkspace(sessionID: "session", workspaceKey: second.key!, index: 1),
        ]

        let ordered = PersonalSidebar.order([first, second], rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.workspaceKey.rawValue, $0) }))

        #expect(ordered.map { $0.key?.rawValue } == ["key-a", "key-b"])
    }
}
