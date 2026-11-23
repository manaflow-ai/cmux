@testable import CmuxNextDaemon
import CmuxNextHomeEngine
import Foundation
import Testing

/// B16 of the classic handoff, the durable form: the daemon marks its "Recovered terminals"
/// workspace (`workspace-recovered-v1`, `"recovered": true` in the raw tree), and the first launch
/// reads that mark instead of the workspace's name. The name is only the fallback for a daemon
/// that sends no mark (`RecoveredTerminalsFirstUseTests`).
@MainActor
struct RecoveredWorkspaceMarkerTests {
    private func workspace(_ json: String) throws -> WorkspaceModel {
        WorkspaceModel(try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8)))
    }

    private func home() throws -> WorkspaceModel {
        try workspace(#"{"id":1,"key":"k-1","name":"Home","kind":"home"}"#)
    }

    /// A marked recovery workspace is not prior use under any name (a renamed one, a language the
    /// fallback does not list).
    @Test func aMarkedRecoveryWorkspaceIsNotPriorUse() throws {
        let tree = [try home(), try workspace(#"{"id":2,"key":"k-2","name":"Wiederhergestellt","recovered":true}"#)]
        #expect(tree.needsFirstWorkspace(leftover: []))
    }

    /// A daemon that sends the mark is the authority: a workspace it says is not recovered counts,
    /// whatever its name.
    @Test func anUnmarkedWorkspaceNamedLikeTheRecoveryOneCounts() throws {
        let tree = [try home(), try workspace(#"{"id":2,"key":"k-2","name":"Recovered terminals","recovered":false}"#)]
        #expect(!tree.needsFirstWorkspace(leftover: []))
    }
}
