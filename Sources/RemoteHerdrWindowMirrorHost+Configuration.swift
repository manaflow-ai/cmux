import Bonsplit
import Foundation

@MainActor
extension RemoteHerdrWindowMirrorHost {
    /// Keeps the embedded mirror chrome in sync with the workspace Bonsplit theme.
    func observeWorkspaceBonsplitConfiguration() {
        guard let workspaceBonsplitController else { return }
        applyWorkspaceBonsplitConfiguration(workspaceBonsplitController.configuration)
    }

    func applyWorkspaceBonsplitConfiguration(_ workspaceConfiguration: BonsplitConfiguration) {
        bonsplitController.configuration = workspaceConfiguration.remoteTmuxEmbedded
    }
}
