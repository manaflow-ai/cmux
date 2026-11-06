@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloudUI
import Foundation
import Testing

/// A chat's folder that left this Mac while its Cloud machine came up (a worktree removed meanwhile) is found
/// before the copy and said in one plain line: no machine or lease name, no OS error, and no Retry, which could
/// only fail the same way. The person picks another folder (the card) or starts without one (the toast).
/// Leo, 2026-11-06, on "Couldn't copy the folder to lease-lease_u_…: cannot list …: No such file or directory
/// (os error 2)": "what's this".
@Suite
@MainActor
struct CloudStartChatFolderGoneTests {
    @Test func aFolderRemovedBeforeTheCopyIsSaidPlainlyWithNoMachineOrOSError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("contract--followups-3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = CloudMove.Failure(message: CloudMoveStrings.syncFailed("lease-lease_u_5aa53d2a", "cannot list \(folder.path): No such file or directory (os error 2)"))
        // A copy that failed with its folder still there keeps its own failure (and its Retry).
        #expect(await CloudStartFolderGone.or(raw, root: folder.path, folder: "contract--followups-3") is CloudMove.Failure)
        try FileManager.default.removeItem(at: folder)
        let gone = try #require(await CloudStartFolderGone.or(raw, root: folder.path, folder: "contract--followups-3") as? CloudStartFolderGone)
        #expect(gone.message.contains("contract--followups-3"))
        for raw in ["os error", "No such file", "lease", folder.path, "\n"] { #expect(!gone.message.contains(raw), "\(raw)") }
        // The card words it by the pane's own code ("This folder no longer exists; pick another one"), never as a failed step.
        let reply = AgentPaneCloudStart.folderGoneReply
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "cloud_folder_missing")
        #expect(AgentPaneHandOff.refusedHere(reply) == "cloud_folder_missing")
    }

    @Test func startingWithoutAFolderKeepsTheSendAndCopiesNothing() {
        var start = AgentPaneCloudStart(task: "fix the build", cwd: "/Users/me/Projects/checkouts/cmux/contract--followups-3", harness: "claude", key: "send-1")
        start.uploadRoot = "/Users/me/Projects/checkouts/cmux/contract--followups-3"
        let bare = start.withoutFolder
        #expect(bare.home && bare.cwd == nil && bare.uploadRoot == nil)
        // The same send, so the machine already made for it is the one it starts on.
        #expect(bare.key == "send-1" && bare.task == "fix the build" && bare.harness == "claude")
        #expect(!CloudMoveStrings.startWithoutFolder.isEmpty)
    }
}
