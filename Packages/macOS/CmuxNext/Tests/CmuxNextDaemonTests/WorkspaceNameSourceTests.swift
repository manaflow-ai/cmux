import Foundation
import Testing
@testable import CmuxNextDaemon

struct WorkspaceNameSourceTests {
    @Test(arguments: ["", "  ", "~", "workspace-7"])
    func legacyAndDaemonDefaultsAreAvailableToTheAutomaticNamer(_ name: String) {
        #expect(WorkspaceModel.isDefaultName(name))
    }

    @Test(arguments: ["Release notes", "workspace-api", "~ notes"])
    func meaningfulNamesRemainUserNames(_ name: String) {
        #expect(!WorkspaceModel.isDefaultName(name))
    }

    @Test @MainActor func aUserRenamedHomeMarkerIsNotUnnamed() throws {
        let snapshot = WorkspaceSnapshot(id: 1, key: "manual", name: "~", nameSource: .user, nameRevision: 1)
        #expect(!WorkspaceModel(snapshot).isUnnamed)
    }

    @Test @MainActor func aRequestedHomeMarkerIsNotUnnamed() {
        let snapshot = WorkspaceSnapshot(id: 1, key: "requested", name: "~", nameSource: .user)
        #expect(!WorkspaceModel(snapshot).isUnnamed)
    }

    @Test func legacySnapshotDefaultsToManualOwnership() throws {
        let snapshot = try Self.decodeSnapshot("""
        {"id":1,"key":"legacy","name":"Claude Code","screens":[]}
        """)

        #expect(snapshot.nameSource == .user)
        #expect(snapshot.nameRevision == 0)
    }

    @Test func snapshotDecodesAutomaticOwnershipAndDecimalRevision() throws {
        let snapshot = try Self.decodeSnapshot("""
        {"id":1,"key":"auto","name":"Deploy API","name_source":"auto","name_revision":"7","screens":[]}
        """)

        #expect(snapshot.nameSource == .auto)
        #expect(snapshot.nameRevision == 7)
    }

    @Test @MainActor func modelUpdateCarriesNameAuthority() throws {
        let initial = try Self.decodeSnapshot("""
        {"id":1,"key":"model","name":"Claude Code","name_source":"user","name_revision":"2","screens":[]}
        """)
        let model = WorkspaceModel(initial)
        let updated = try Self.decodeSnapshot("""
        {"id":1,"key":"model","name":"Deploy API","name_source":"auto","name_revision":"3","screens":[]}
        """)

        model.update(updated)

        #expect(model.nameSource == .auto)
        #expect(model.nameRevision == 3)
        #expect(model.displayName == "Deploy API")
    }

    @Test func manualRenameRequestKeepsLegacyWireShape() throws {
        let request = RenameWorkspaceRequest(workspace: .key(WorkspaceKey(rawValue: "manual")), name: "Manual", mutation: nil)
        let object = try Self.object(request)

        #expect(object["name"] as? String == "Manual")
        #expect(object["source"] == nil)
        #expect(object["expected_name_revision"] == nil)
        #expect(object["release"] == nil)
    }

    @Test func automaticRenameRequestUsesDecimalRevision() throws {
        let request = RenameWorkspaceRequest(workspace: .key(WorkspaceKey(rawValue: "auto")), name: "Deploy API",
                                              source: .auto, expectedNameRevision: 7, release: false, mutation: nil)
        let object = try Self.object(request)

        #expect(object["source"] as? String == "auto")
        #expect(object["expected_name_revision"] as? String == "7")
        #expect(object["release"] == nil)
    }

    private static func decodeSnapshot(_ json: String) throws -> WorkspaceSnapshot {
        try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
    }

    private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
}
