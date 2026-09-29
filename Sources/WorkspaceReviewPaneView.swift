import CmuxFoundation
import SwiftUI

/// Observes directory provenance above the immutable finding-row boundary.
struct WorkspaceReviewPaneView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        ReviewPaneView(
            directory: workspace.usesRemoteDirectoryProvenance ? nil : workspace.currentDirectory,
            cliPath: cliPath,
            commands: CommandRunner()
        )
    }

    /// The pane remains useful when a development/test bundle omits the
    /// embedded CLI: it can still explain that no local reviews are available,
    /// while a normal app bundle resolves the exact executable it ships.
    private var cliPath: String {
        if let cli = CLIForwardingLaunchRouter.bundledCLIURL() {
            return cli.path
        }
        if let configured = ProcessInfo.processInfo.environment["CMUX_BUNDLED_CLI_PATH"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configured
        }
        return "cmux"
    }
}
