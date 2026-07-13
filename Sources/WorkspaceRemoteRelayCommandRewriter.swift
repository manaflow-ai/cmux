import CmuxRemoteWorkspace
import Foundation

/// App-side conformance to the relay's command-rewrite seam: forwards to the
/// workspace model's alias-aware static rewrite so the package never imports
/// `Workspace`.
struct WorkspaceRemoteRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        Workspace.rewriteRemoteRelayCommandLine(
            commandLine,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        )
    }
}
