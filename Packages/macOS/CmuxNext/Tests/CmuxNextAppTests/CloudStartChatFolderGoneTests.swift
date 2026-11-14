@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// A chat's folder that left this Mac while its Cloud machine came up (a worktree removed meanwhile) is said by the
/// card's own `cloud_folder_missing` refusal: no machine or lease name, no OS error, and no Retry, which could only
/// fail the same way. Leo, 2026-11-06, on "Couldn't copy the folder to lease-lease_u_…: cannot list …: No such file
/// or directory (os error 2)": "what's this".
@Suite
@MainActor
struct CloudStartChatFolderGoneTests {
    @Test func aFolderRemovedDuringTheStartIsTheCardsOwnRefusalWithNoMachineOrOSError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("contract--followups-3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = CloudMove.Failure(message: CloudMoveStrings.syncFailed("lease-lease_u_5aa53d2a", "cannot list \(folder.path): No such file or directory (os error 2)"),
                                    retry: .move(machineID: "m1"))
        // A copy that failed with its folder still there keeps its own failure (and its Retry).
        #expect(await CloudMoveFolder.orGone(raw, root: folder.path) is CloudMove.Failure)
        try FileManager.default.removeItem(at: folder)
        #expect(await CloudMoveFolder.orGone(raw, root: folder.path) is CloudMoveFolder.Gone)
        // The card words it by the pane's own code ("This folder no longer exists; pick another one"), never as a failed step.
        let reply = AgentPaneCloudFolderRefusal.missing.reply
        #expect(reply["ok"] as? Bool == false)
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "cloud_folder_missing")
        #expect(error["retryable"] == nil)
        #expect(AgentPaneHandOff.refusedHere(reply) == "cloud_folder_missing")
        for raw in ["os error", "No such file", "lease", folder.path] { #expect(!"\(reply)".contains(raw), "\(raw)") }
    }
}
