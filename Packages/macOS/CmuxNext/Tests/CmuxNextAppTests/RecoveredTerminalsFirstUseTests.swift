@testable import CmuxNextDaemon
import CmuxNextHomeEngine
import Testing

/// B16 of the classic handoff (plans/cmux-next/classic-handoff-go-live-RUNBOOK.md): terminal hosts a
/// previous cmux-next daemon left running come back in the daemon's "Recovered terminals" workspace
/// (cmux-tui `mux/orphan_hosts.rs`). The person never made it, so it is not prior use: the launch
/// still gives the tree its first workspace, and the first contact with classic still asks to import
/// instead of recording a baseline that marks every classic workspace done (lab run B, RC 8).
@MainActor
struct RecoveredTerminalsFirstUseTests {
    private func workspace(_ handle: UInt64, _ name: String, kind: String? = nil) -> WorkspaceModel {
        var snapshot = WorkspaceSnapshot(id: WorkspaceHandle(rawValue: handle), key: WorkspaceKey(rawValue: "k-\(handle)"), name: name)
        snapshot.kind = kind
        return WorkspaceModel(snapshot)
    }

    /// The daemon names the workspace in its own language: English and Japanese.
    @Test(arguments: ["Recovered terminals", "復元されたターミナル"])
    func onlyRecoveredTerminalsIsNotPriorUse(name: String) {
        let tree = [workspace(1, "Home", kind: "home"), workspace(2, name)]
        #expect(tree.needsFirstWorkspace(leftover: []))
    }

    @Test func aWorkspaceOfThePersonsOwnBesideItStillCounts() {
        let tree = [workspace(1, "Home", kind: "home"), workspace(2, "Recovered terminals"), workspace(3, "api server")]
        #expect(!tree.needsFirstWorkspace(leftover: []))
    }
}
