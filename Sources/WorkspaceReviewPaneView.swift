import CmuxFoundation
import SwiftUI

/// Observes directory provenance above the immutable finding-row boundary.
struct WorkspaceReviewPaneView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if let cli = CLIForwardingLaunchRouter.bundledCLIURL() {
            ReviewPaneView(
                directory: workspace.usesRemoteDirectoryProvenance ? nil : workspace.currentDirectory,
                cliPath: cli.path,
                commands: CommandRunner()
            )
        }
    }
}
